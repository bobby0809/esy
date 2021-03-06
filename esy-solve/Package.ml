open EsyInstall.PackageConfig
module String = Astring.String

[@@@ocaml.warning "-32"]
type 'a disj = 'a list [@@deriving ord]
[@@@ocaml.warning "-32"]
type 'a conj = 'a list [@@deriving ord]


let isOpamPackageName name =
  match String.cut ~sep:"/" name with
  | Some ("@opam", _) -> true
  | _ -> false

module Dep = struct
  type t = {
    name : string;
    req : req;
  } [@@deriving ord]

  and req =
    | Npm of EsyInstall.SemverVersion.Constraint.t
    | NpmDistTag of string
    | Opam of EsyInstall.OpamPackageVersion.Constraint.t
    | Source of EsyInstall.SourceSpec.t

  let pp fmt {name; req;} =
    let ppReq fmt = function
      | Npm c -> EsyInstall.SemverVersion.Constraint.pp fmt c
      | NpmDistTag tag -> Fmt.string fmt tag
      | Opam c -> EsyInstall.OpamPackageVersion.Constraint.pp fmt c
      | Source src -> EsyInstall.SourceSpec.pp fmt src
    in
    Fmt.pf fmt "%s@%a" name ppReq req

end

let yojson_of_reqs (deps : EsyInstall.Req.t list) =
  let f (x : EsyInstall.Req.t) = `List [`Assoc [x.name, (EsyInstall.VersionSpec.to_yojson x.spec)]] in
  `List (List.map ~f deps)

module Dependencies = struct

  type t =
    | OpamFormula of Dep.t disj conj
    | NpmFormula of NpmFormula.t
    [@@deriving ord]

  let toApproximateRequests = function
    | NpmFormula reqs -> reqs
    | OpamFormula reqs ->
      let reqs =
        let f reqs deps =
          let f reqs (dep : Dep.t) =
            let spec =
              match dep.req with
              | Dep.Npm _ -> EsyInstall.VersionSpec.Npm [[EsyInstall.SemverVersion.Constraint.ANY]]
              | Dep.NpmDistTag tag -> EsyInstall.VersionSpec.NpmDistTag tag
              | Dep.Opam _ -> EsyInstall.VersionSpec.Opam [[EsyInstall.OpamPackageVersion.Constraint.ANY]]
              | Dep.Source srcSpec -> EsyInstall.VersionSpec.Source srcSpec
            in
            EsyInstall.Req.Set.add (EsyInstall.Req.make ~name:dep.name ~spec) reqs
          in
          List.fold_left ~f ~init:reqs deps
        in
        List.fold_left ~f ~init:EsyInstall.Req.Set.empty reqs
      in
      EsyInstall.Req.Set.elements reqs

  let pp fmt deps =
    match deps with
    | OpamFormula deps ->
      let ppDisj fmt disj =
        match disj with
        | [] -> Fmt.unit "true" fmt ()
        | [dep] -> Dep.pp fmt dep
        | deps -> Fmt.pf fmt "(%a)" Fmt.(list ~sep:(unit " || ") Dep.pp) deps
      in
      Fmt.pf fmt "@[<h>%a@]" Fmt.(list ~sep:(unit " && ") ppDisj) deps
    | NpmFormula deps -> NpmFormula.pp fmt deps

  let show deps =
    Format.asprintf "%a" pp deps

  let filterDependenciesByName ~name deps =
    let findInNpmFormula reqs =
      let f req = req.EsyInstall.Req.name = name in
      List.filter ~f reqs
    in
    let findInOpamFormula cnf =
      let f disj =
        let f dep = dep.Dep.name = name in
        List.exists ~f disj
      in
      List.filter ~f cnf
    in
    match deps with
    | NpmFormula f -> NpmFormula (findInNpmFormula f)
    | OpamFormula f -> OpamFormula (findInOpamFormula f)

  let to_yojson = function
    | NpmFormula deps -> yojson_of_reqs deps
    | OpamFormula deps ->
      let ppReq fmt = function
        | Dep.Npm c -> EsyInstall.SemverVersion.Constraint.pp fmt c
        | Dep.NpmDistTag tag -> Fmt.string fmt tag
        | Dep.Opam c -> EsyInstall.OpamPackageVersion.Constraint.pp fmt c
        | Dep.Source src -> EsyInstall.SourceSpec.pp fmt src
      in
        let jsonOfItem {Dep. name; req;} = `Assoc [name, `String (Format.asprintf "%a" ppReq req)] in
        let f disj = `List (List.map ~f:jsonOfItem disj) in
          `List (List.map ~f deps)
end

type t = {
  name : string;
  version : EsyInstall.Version.t;
  originalVersion : EsyInstall.Version.t option;
  originalName : string option;
  source : EsyInstall.PackageSource.t;
  overrides : EsyInstall.Overrides.t;
  dependencies: Dependencies.t;
  devDependencies: Dependencies.t;
  peerDependencies: NpmFormula.t;
  optDependencies: StringSet.t;
  resolutions : EsyInstall.PackageConfig.Resolutions.t;
  kind : kind;
}

and kind =
  | Esy
  | Npm

let pp fmt pkg =
  Fmt.pf fmt "%s@%a" pkg.name EsyInstall.Version.pp pkg.version

let compare pkga pkgb =
  let name = String.compare pkga.name pkgb.name in
  if name = 0
  then EsyInstall.Version.compare pkga.version pkgb.version
  else name

let to_yojson pkg =
  `Assoc [
    "name", `String pkg.name;
    "version", `String (EsyInstall.Version.showSimple pkg.version);
    "dependencies", Dependencies.to_yojson pkg.dependencies;
    "devDependencies", Dependencies.to_yojson pkg.devDependencies;
    "peerDependencies", yojson_of_reqs pkg.peerDependencies;
    "optDependencies", `List (List.map ~f:(fun x -> `String x) (StringSet.elements pkg.optDependencies));
  ]

module Map = Map.Make(struct
  type nonrec t = t
  let compare = compare
end)

module Set = Set.Make(struct
  type nonrec t = t
  let compare = compare
end)
