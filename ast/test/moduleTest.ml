(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Ast
open Test

let test_empty_stub _ =
  assert_true
    ( Module.create_for_testing
        ~local_mode:(Some (Node.create_with_default_location Source.PlaceholderStub))
        ~stub:true
    |> Module.empty_stub );
  assert_false
    ( Module.create_for_testing
        ~local_mode:(Some (Node.create_with_default_location Source.PlaceholderStub))
        ~stub:false
    |> Module.empty_stub );
  assert_false (Module.create_for_testing ~local_mode:None ~stub:true |> Module.empty_stub)


let test_aliased_export _ =
  let assert_aliased_exports ?(handle = "") source aliased_exports =
    let module_definition = Module.create (parse ~handle source) in
    let assert_aliased_export (source, expected_target) =
      let actual_target =
        Reference.create source
        |> Module.legacy_aliased_export module_definition
        |> (fun value -> Option.value value ~default:(Reference.create "$not_exported"))
        |> Reference.show
      in
      assert_equal ~printer:Fn.id expected_target actual_target
    in
    List.iter ~f:assert_aliased_export aliased_exports
  in
  assert_aliased_exports
    {|
      from other.module import Class
      from different.module import function
      import blah
      import standard_library_module as module
    |}
    [
      "Class", "other.module.Class";
      "function", "different.module.function";
      "blah", "blah";
      "module", "standard_library_module";
    ];
  assert_aliased_exports "from some.module import aliased as alias" ["alias", "some.module.aliased"];
  assert_aliased_exports
    "from some.module import one, two"
    ["one", "some.module.one"; "two", "some.module.two"];
  assert_aliased_exports "from some.module import *" ["*", "some.module"];
  assert_aliased_exports
    ~handle:"some/module.py"
    "from . import path as other"
    ["other", "some.path"];
  assert_aliased_exports
    ~handle:"some/long/module.py"
    "from .relative import path as other"
    ["other", "some.long.relative.path"];
  assert_aliased_exports
    ~handle:"some/long/module.py"
    "from ..relative import path as other"
    ["other", "some.relative.path"];
  assert_aliased_exports
    ~handle:"some/long/module.py"
    "from ...relative import path as other"
    ["other", "relative.path"];
  assert_aliased_exports
    ~handle:"some/module.py"
    "from some.module.derp import path as other"
    ["other", "some.module.derp.path"];
  assert_aliased_exports
    ~handle:"some/module.py"
    "from some.module.other import other as other"
    ["other", "some.module.other.other"];
  assert_aliased_exports "from builtins import path as other" ["other", "path"];
  assert_aliased_exports
    {|
      from other import thing
      from other import thing
    |}
    ["thing", "other.thing"];

  (* Global assignments should not be counted *)
  assert_aliased_exports
    ~handle:"requests.py"
    {|
      from . import api
      post = requests.api.post
      call = requests.api.call()
      not_exported = other.assignment
    |}
    [];
  ()


let test_exports context =
  let assert_exports ?(is_stub = false) ~expected source_text =
    let actual =
      let handle = if is_stub then "test.pyi" else "test.py" in
      parse ~handle source_text |> Module.create |> Module.get_all_exports
    in
    let expected = List.sort expected ~compare:[%compare: Identifier.t * Module.Export.t] in
    assert_equal
      ~ctxt:context
      ~cmp:[%compare.equal: (Identifier.t * Module.Export.t) list]
      ~printer:(fun exports ->
        Sexp.to_string_hum [%message (exports : (Identifier.t * Module.Export.t) list)])
      expected
      actual
  in

  let open Module.Export in
  assert_exports
    {|
      import a.b
      import c.d as e
      from f.g import h
      from i.j import k as l
    |}
    ~expected:
      [
        "a", Module !&"a";
        "e", Module !&"c.d";
        "h", NameAlias { from = !&"f.g"; name = "h" };
        "l", NameAlias { from = !&"i.j"; name = "k" };
      ];
  assert_exports
    {|
      import a.b
      import c.d as e
      from f.g import h
      from i.j import k as l
    |}
    ~is_stub:true
    ~expected:["e", Module !&"c.d"; "l", NameAlias { from = !&"i.j"; name = "k" }];
  assert_exports
    {|
       def foo() -> None: pass
       class Bar: pass
       baz = 42
    |}
    ~expected:["foo", Define; "Bar", Class; "baz", GlobalVariable];
  assert_exports
    {|
       if derp():
         x = 42
       else:
         if herp():
           y = 43
         z = 44
    |}
    ~expected:["x", GlobalVariable; "y", GlobalVariable; "z", GlobalVariable];
  assert_exports
    {|
       try:
         try:
           x = 42
         except:
           y = 43
       except:
         z = 43
       finally:
         w = 44
    |}
    ~expected:["x", GlobalVariable; "y", GlobalVariable; "z", GlobalVariable; "w", GlobalVariable];
  assert_exports
    {|
       import foo
       def foo(): pass
    |} (* Last definition wins *)
    ~expected:["foo", Define];
  assert_exports
    {|
       if derp():
         from bar import foo
       else:
         foo = 42
    |}
    (* Unfortunately since we don't really follow control we can't really join the two. *)
    ~expected:["foo", GlobalVariable];
  ()


let () =
  "module"
  >::: [
         "empty_stub" >:: test_empty_stub;
         "aliased_export" >:: test_aliased_export;
         "exports" >:: test_exports;
       ]
  |> Test.run
