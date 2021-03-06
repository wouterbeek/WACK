:- module(
  ppm,
  [
    ppm_help/0,
    ppm_install/2, % +User, +Repo
    ppm_list/0,
    ppm_remove/2,  % +User, +Repo
    ppm_run/2,     % +User, +Repo
    ppm_sync/0,
    ppm_update/0,
    ppm_update/2,  % +User, +Repo
    ppm_updates/0
  ]
).

/** <module> Prolog Package Manager (PPM)

A simple package manager for SWI-Prolog.

---

@author Wouter Beek
@version 2017-2018
*/

:- use_module(library(aggregate)).
:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(library(git)).
:- use_module(library(http/http_json), []).
:- use_module(library(prolog_pack), []).

:- use_module(library(ppm_generic)).
:- use_module(library(ppm_git)).
:- use_module(library(ppm_github)).

:- initialization
   init_ppm.





%! ppm_current_update(?User:atom, ?Repo:atom, -CurrentVersion:compound,
%!                    -LatestVersion:compound) is nondet.

ppm_current_update(User, Repo, CurrentVersion, LatestVersion) :-
  repository_directory(User, Repo, Dir),
  git_fetch(Dir),
  git_current_version(Dir, CurrentVersion),
  git_version_latest(Dir, LatestVersion),
  CurrentVersion \== LatestVersion.



%! ppm_help is det.

ppm_help :-
  ansi_format([fg(green)], "Welcome "),
  ansi_format([fg(red)], "to "),
  ansi_format([fg(blue)], "Prolog "),
  ansi_format([fg(yellow)], "Package "),
  ansi_format([fg(magenta)], "Manager"),
  format("!"),
  nl,
  format("We are so happy that you're here :-)"),
  nl,
  nl.



%! ppm_install(+User:atom, +Repo:atom) is semidet.
%
% Installs a package.  The latests version is chosen in case none is
% specified.

ppm_install(User, Repo) :-
  ppm_install(User, Repo, package).

ppm_install(User, Repo, Kind) :-
  repository_directory(User, Repo, _), !,
  ppm_update(User, Repo, Kind).
ppm_install(User, Repo, Kind) :-
  user_directory(User, UserDir),
  (   github_version_latest(User, Repo, LatestVersion)
  ->  github_uri(User, Repo, Uri),
      git_clone(UserDir, Uri),
      directory_file_path(UserDir, Repo, RepoDir),
      git_checkout(RepoDir, version(LatestVersion)),
      ppm_dependencies(RepoDir, Dependencies),
      maplist(ppm_install_dependency, Dependencies),
      phrase(version(LatestVersion), Codes),
      ansi_format(
        [fg(green)],
        "Successfully installed ~a ‘~a’ (~s)\n",
        [Kind,Repo,Codes]
      ),
      ppm_sync
  ;   ansi_format(
        [fg(red)],
        "Could not find a version tag in ~a's ~a ‘~a’.",
        [User,Kind,Repo]
      ),
      nl,
      fail
  ).

ppm_install_dependency(Dependency) :-
  _{user: User, repo: Repo} :< Dependency,
  ppm_install(User, Repo, dependency).



%! ppm_list is det.
%
% Display all currently installed PPMs.

ppm_list :-
  aggregate_all(
    set(package(User,Repo,Version,Dependencies)),
    (
      repository_directory(User, Repo, Dir),
      git_current_version(Dir, Version),
      ppm_dependencies(Dir, Dependencies)
    ),
    Packages
  ),
  (   Packages == []
  ->  format("No packages are currently installed.\n")
  ;   maplist(ppm_list_row, Packages)
  ).

ppm_list_row(package(User,Repo,Version,Dependencies)) :-
  phrase(version(Version), Codes),
  format("~a/~a (~s)\n", [User,Repo,Codes]),
  maplist(ppm_list_dep_row, Dependencies).

ppm_list_dep_row(Dependency) :-
  _{user: User, repo: Repo} :< Dependency,
  format("  ⤷ ~a/~a\n", [User,Repo]).



%! ppm_remove(+User:atom, +Repo:atom) is det.
%
% Removes a package.
%
% TBD: Support for removing otherwise unused dependencies.

ppm_remove(User, Repo) :-
  repository_directory(User, Repo, Dir),
  git_current_version(Dir, Version),
  delete_directory_and_contents(Dir),
  phrase(version(Version), Codes),
  format("Deleted package ‘~a/~a’ (~s).", [User,Repo,Codes]).



%! ppm_run(+User:atom, +Repo:atom) is semidet.

ppm_run(User, Repo) :-
  repository_directory(User, Repo, Dir),
  (   file_by_name(Dir, 'run.pl', File)
  ->  consult(File)
  ;   ansi_format([fg(red)], "Package ‘~a/~a’ is currently not installed.\n", [User,Repo])
  ).



%! ppm_sync is det.
%
% Synchronizes the packages the current Prolog session has access to
% the to packages stored in `~/.ppm'.

ppm_sync :-
  root_directory(Root),
  ppm_sync_(Root).

ppm_sync_(Root) :-
  assertz(user:file_search_path(ppm, Root)),
  current_prolog_flag(arch, Arch),
  forall(
    repository_directory(User, Repo, _),
    (
      (   sync_directory(Root, User, Repo, [prolog], Dir)
      ->  assertz(user:file_search_path(library, ppm(Dir)))
      ;   true
      ),
      (   sync_directory(Root, User, Repo, [lib,Arch], Dir)
      ->  assertz(user:file_search_path(foreign, ppm(Dir)))
      ;   true
      )
    )
  ).

sync_directory(Root, User, Repo, T, Dir) :-
  atomic_list_concat([User,Repo|T], /, Dir),
  directory_by_name(Root, Dir).



%! ppm_update is semidet.
%! ppm_update(+User, +Repo:atom) is semidet.
%
% Updates an exisiting package and all of its dependencies.

ppm_update :-
  ppm_updates_(Updates),
  forall(
    member(update(User,Repo,_,_), Updates),
    ppm_update(User, Repo)
  ).


ppm_update(User, Repo) :-
  ppm_update(User, Repo, package).


ppm_update(User, Repo, Kind) :-
  repository_directory(User, Repo, Dir),
  git_fetch(Dir),
  git_current_version(Dir, CurrentVersion),
  git_version_latest(Dir, LatestVersion),
  (   compare_version(<, CurrentVersion, LatestVersion)
  ->  git_checkout(Dir, version(LatestVersion)),
      % informational
      phrase(version(CurrentVersion), Codes1),
      phrase(version(LatestVersion), Codes2),
      format("Updated ‘~a/~a’: ~s → ~s\n", [User,Repo,Codes1,Codes2])
  ;   % informational
      (   Kind == package
      ->  format("No need to update ~a ‘~a/~a’.\n", [Kind,User,Repo])
      ;   true
      )
  ),
  % Update the dependencies after updating the main package.
  ppm_dependencies(Dir, Dependencies),
  maplist(ppm_install_dependency, Dependencies),
  ppm_sync.

ppm_update_dependency(Dependency) :-
  _{user: User, repo: Repo} :< Dependency,
  ppm_update(User, Repo, dependency).



%! ppm_updates is det.
%
% Shows packages, if any, that can be updated using ppm_update/1.

ppm_updates :-
  format("Checking for updates…\n\n"),
  ppm_updates_(Updates),
  pp_available_updates(Updates),
  maplist(ppm_updates_row, Updates).

ppm_updates_(Updates) :-
  aggregate_all(
    set(update(User,Repo,CurrentVersion,LatestVersion)),
    ppm_current_update(User, Repo, CurrentVersion, LatestVersion),
    Updates
  ).

pp_available_updates([]) :- !,
  format("No updates available.\n").
pp_available_updates([_]) :- !,
  format("1 update available:\n").
pp_available_updates(Updates) :-
  length(Updates, N),
  format("~D updates available:\n", [N]).

ppm_updates_row(update(User,Repo,CurrentVersion,LatestVersion)) :-
  format("  • ~a/~a\t", [User,Repo]),
  compare_version(Order, CurrentVersion, LatestVersion),
  order_colors(Order, Color1, Color2),
  phrase(version(CurrentVersion), CurrentCodes),
  ansi_format([fg(Color1)], "~s", [CurrentCodes]),
  format(" → "),
  phrase(version(LatestVersion), LatestCodes),
  ansi_format([fg(Color2)], "~s\n", [LatestCodes]).

order_colors(<, red, green).
order_colors(>, green, red).





% INITIALIZATION %

init_ppm :-
  root_directory(Root),
  ensure_directory_exists(Root),
  ppm_sync_(Root).
