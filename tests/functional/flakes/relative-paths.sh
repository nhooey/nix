#!/usr/bin/env bash

source ./common.sh

requireGit

rootFlake="$TEST_ROOT/flake1"
subflake0="$rootFlake/sub0"
subflake1="$rootFlake/sub1"
subflake2="$rootFlake/sub2"

mkdir -p "$rootFlake" "$subflake0" "$subflake1" "$subflake2"

cat > "$rootFlake/flake.nix" <<EOF
{
  inputs.sub0.url = ./sub0;
  outputs = { self, sub0 }: {
    x = 2;
    y = self.x * sub0.x;
  };
}
EOF

cat > "$subflake0/flake.nix" <<EOF
{
  outputs = { self }: {
    x = 7;
  };
}
EOF

[[ $(nix eval "$rootFlake#x") = 2 ]]
[[ $(nix eval "$rootFlake#y") = 14 ]]

cat > "$subflake1/flake.nix" <<EOF
{
  inputs.root.url = "../";
  outputs = { self, root }: {
    x = 3;
    y = self.x * root.x;
  };
}
EOF

[[ $(nix eval "$rootFlake?dir=sub1#y") = 6 ]]

initGitRepo "$rootFlake"
git -C "$rootFlake" add flake.nix sub0/flake.nix sub1/flake.nix

[[ $(nix eval "$subflake1#y") = 6 ]]

cat > "$subflake2/flake.nix" <<EOF
{
  inputs.root.url = ./..;
  inputs.sub1.url = "../sub1";
  outputs = { self, root, sub1 }: {
    x = 5;
    y = self.x * sub1.x;
  };
}
EOF

git -C "$rootFlake" add flake.nix sub2/flake.nix

[[ $(nix eval "$subflake2#y") = 15 ]]

# Make sure that this still works after committing the lock file.
git -C "$rootFlake" add sub2/flake.lock
[[ $(nix eval "$subflake2#y") = 15 ]]

# Relative path inputs must not make prefetch-inputs fail.
nix flake prefetch-inputs "$subflake2"

[[ $(jq --indent 0 --compact-output . < "$subflake2/flake.lock") =~ ^'{"nodes":{"root":{"inputs":{"root":"root_2","sub1":"sub1"}},"root_2":{"inputs":{"sub0":"sub0"},"locked":{"path":"..","type":"path"},"original":{"path":"..","type":"path"},"parent":[]},"root_3":{"inputs":{"sub0":"sub0_2"},"locked":{"path":"../","type":"path"},"original":{"path":"../","type":"path"},"parent":["sub1"]},"sub0":{"locked":{"path":"sub0","type":"path"},"original":{"path":"sub0","type":"path"},"parent":["root"]},"sub0_2":{"locked":{"path":"sub0","type":"path"},"original":{"path":"sub0","type":"path"},"parent":["sub1","root"]},"sub1":{"inputs":{"root":"root_3"},"locked":{"path":"../sub1","type":"path"},"original":{"path":"../sub1","type":"path"},"parent":[]}},"root":"root","version":7}'$ ]]

# Make sure there are no content locks for relative path flakes.
(! grep "$TEST_ROOT" "$subflake2/flake.lock")
if ! isTestOnNixOS; then
    (! grep "$NIX_STORE_DIR" "$subflake2/flake.lock")
fi
(! grep narHash "$subflake2/flake.lock")

# Test `nix flake archive` with relative path flakes.
git -C "$rootFlake" add flake.lock
git -C "$rootFlake" commit -a -m Foo

json=$(nix flake archive --json "$rootFlake" --to "$TEST_ROOT/store2")
[[ $(echo "$json" | jq .inputs.sub0.inputs) = {} ]]
[[ -n $(echo "$json" | jq .path) ]]

nix flake prefetch --out-link "$TEST_ROOT/result" "$rootFlake"
outPath=$(readlink "$TEST_ROOT/result")

[ -e "$TEST_ROOT/store2/nix/store/$(basename "$outPath")" ]

# Test circular relative path flakes. FIXME: doesn't work at the moment.
if false; then

cat > "$rootFlake/flake.nix" <<EOF
{
  inputs.sub1.url = "./sub1";
  inputs.sub2.url = "./sub1";
  outputs = { self, sub1, sub2 }: {
    x = 2;
    y = self.x * sub1.x * sub2.x;
    z = sub1.y * sub2.y;
  };
}
EOF

[[ $(nix eval "$rootFlake#x") = 30 ]]
[[ $(nix eval "$rootFlake#z") = 90 ]]

fi

# https://github.com/NixOS/nix/pull/10089#discussion_r2041984987
# https://github.com/NixOS/nix/issues/13018
mkdir -p "$TEST_ROOT/issue-13018/example"
(
  cd "$TEST_ROOT/issue-13018"
  git init
  echo '{ outputs = _: { }; }' >flake.nix
  cat >example/flake.nix <<EOF
{
  inputs.parent.url = ../.;
  outputs = { parent, ... }: builtins.seq parent { ok = null; };
}
EOF
  git add -N .
  cd example
  # Important: the error does not trigger for an in-memory lock!
  nix flake lock
  # would fail:
  nix eval .#ok
)

# https://github.com/NixOS/nix/issues/13164
mkdir -p "$TEST_ROOT/issue-13164/nested-flake1/nested-flake2"
(
  initGitRepo "$TEST_ROOT/issue-13164"
  cd "$TEST_ROOT/issue-13164"
  cat >flake.nix <<EOF
{
  inputs.nestedFlake1.url = "path:./nested-flake1";
  outputs = { self, nestedFlake1 }: {
    inherit nestedFlake1;
  };
}
EOF

  cat >nested-flake1/flake.nix <<EOF
{
  inputs.nestedFlake2.url = "path:./nested-flake2";

  outputs = { self, nestedFlake2 }: {
    name = "nestedFlake1";
    inherit nestedFlake2;
  };
}
EOF

  cat >nested-flake1/nested-flake2/flake.nix <<EOF
{
  outputs = { self }: {
    name = "nestedFlake2";
  };
}
EOF

  git add .
  git commit -m "Initial commit"

  # I don't understand why two calls are necessary to reproduce the issue.
  nix eval --json .#nestedFlake1.nestedFlake2 --no-eval-cache
  nix eval --json .#nestedFlake1.nestedFlake2 --no-eval-cache
)

# A flake input is some location defined by the input plus a subdir (where
# `flake.nix` should be in that location). Subdir composes uniformly across
# schemes: `github:foo/bar?dir=x`, `path:/abs?dir=x`, and `path:./rel?dir=x`
# all locate the flake at `<exposed-source>/x/flake.nix`. So the flake for
# `path:./sub?dir=inner` lives at `<parent>/sub/inner`, despite the quirk
# described in https://github.com/NixOS/nix/issues/16214
mkdir -p "$TEST_ROOT/reldir/sub/inner" "$TEST_ROOT/reldir/alt/deep"
(
  initGitRepo "$TEST_ROOT/reldir"
  cd "$TEST_ROOT/reldir"
  cat >sub/inner/flake.nix <<EOF
{
  outputs = { ... }: { tag = "correct"; };
}
EOF
  cat >flake.nix <<EOF
{
  inputs.sub.url = "path:./sub?dir=inner";
  outputs = { sub, ... }: { tag = sub.tag; };
}
EOF
  git add flake.nix sub/inner/flake.nix
  nix flake lock
  [[ $(nix eval --raw .#tag) = "correct" ]]

  # The subdir must also compose when the input is replaced via
  # --override-input by a ref that itself carries a `?dir=` subdir. This
  # exercises the `hasOverride` branch of call-flake.nix, where the subdir
  # comes from the override's `dir` attribute rather than the lock file.
  # We can't produce a relative path through the CLI yet, so we only test the
  # `--override-input` with an absolute path here.
  cat >alt/deep/flake.nix <<EOF
{
  outputs = { ... }: { tag = "overridden"; };
}
EOF
  git add alt/deep/flake.nix
  [[ $(nix eval --raw --override-input sub "path:$TEST_ROOT/reldir/alt?dir=deep" .#tag) = "overridden" ]]
)

# https://github.com/NixOS/nix/issues/14762
# top -> middle -> library, where 'library' has a relative 'subflake' input.
# 'top' takes 'library' and 'subflake' from middle's lock file, and must
# resolve 'subflake' against library's source tree. 'middle' has a 'subflake'
# directory too, so resolving against middle's tree would pick the wrong flake
# instead of failing.
(
  # 'path:' inputs without a fingerprint can't be cached.
  export _NIX_TEST_BARF_ON_UNCACHEABLE=''

  # Locking again keeps every input and fetches only the flake itself.
  relockKeepsAll() {
    local out
    out=$(nix flake lock --debug "$1" 2>&1)
    grepQuietInverse "creating new input" <<< "$out"
    [[ $(grep -c "^got tree" <<< "$out") = 1 ]]
  }

  n14762="$TEST_ROOT/issue-14762"
  mkdir -p "$n14762/library/subflake" "$n14762/middle/subflake" "$n14762/top"

  cat > "$n14762/library/subflake/flake.nix" <<EOF
{ outputs = _: { v = "library"; }; }
EOF
  cat > "$n14762/middle/subflake/flake.nix" <<EOF
{ outputs = _: { v = "middle"; }; }
EOF
  cat > "$n14762/library/flake.nix" <<EOF
{
  inputs.subflake.url = "path:./subflake";
  outputs = { subflake, ... }: { inherit (subflake) v; };
}
EOF
  cat > "$n14762/middle/flake.nix" <<EOF
{
  inputs.library.url = "path:$n14762/library";
  outputs = { library, ... }: { inherit (library) v; };
}
EOF
  cat > "$n14762/top/flake.nix" <<EOF
{
  inputs.middle.url = "path:$n14762/middle";
  outputs = { middle, ... }: { inherit (middle) v; };
}
EOF

  nix flake lock "$n14762/middle"
  [[ $(nix eval --no-write-lock-file --raw "$n14762/top#v") = library ]]

  # 'subflake' is kept from middle's lock file, not locked again.
  out=$(nix flake lock --debug "$n14762/top" 2>&1)
  grepQuietInverse "creating new input 'middle/library/subflake'" <<< "$out"
  relockKeepsAll "$n14762/top"

  # 'middle2' overrides library's 'subflake' with a relative path of its own.
  # Locking 'top2' again keeps 'middle2' without fetching it, and must still
  # keep the override.
  mkdir -p "$n14762/middle2/mysub" "$n14762/top2"
  cat > "$n14762/middle2/mysub/flake.nix" <<EOF
{ outputs = _: { v = "middle2"; }; }
EOF
  cat > "$n14762/middle2/flake.nix" <<EOF
{
  inputs.library.url = "path:$n14762/library";
  inputs.library.inputs.subflake.url = "path:./mysub";
  outputs = { library, ... }: { inherit (library) v; };
}
EOF
  cat > "$n14762/top2/flake.nix" <<EOF
{
  inputs.middle2.url = "path:$n14762/middle2";
  outputs = { middle2, ... }: { inherit (middle2) v; };
}
EOF
  nix flake lock "$n14762/top2"
  [[ $(nix eval --raw "$n14762/top2#v") = middle2 ]]
  relockKeepsAll "$n14762/top2"

  # Without 'parent', the lock file doesn't say which flake overrides
  # 'subflake', so locking must read middle2's override again.
  jq '(.nodes[] | select(has("parent"))) |= del(.parent)' "$n14762/top2/flake.lock" > "$TEST_ROOT/top2.lock"
  mv "$TEST_ROOT/top2.lock" "$n14762/top2/flake.lock"
  nix flake lock "$n14762/top2"
  [[ $(nix eval --raw "$n14762/top2#v") = middle2 ]]
  relockKeepsAll "$n14762/top2"

  # An override in a flake that is read again isn't taken from the lock file,
  # so removing it locks 'subflake' relative to 'library' again.
  mkdir -p "$n14762/top3/mysub"
  cat > "$n14762/top3/mysub/flake.nix" <<EOF
{ outputs = _: { v = "top3"; }; }
EOF
  cat > "$n14762/top3/flake.nix" <<EOF
{
  inputs.library.url = "path:$n14762/library";
  inputs.library.inputs.subflake.url = "path:./mysub";
  outputs = { library, ... }: { inherit (library) v; };
}
EOF
  nix flake lock "$n14762/top3"
  [[ $(nix eval --raw "$n14762/top3#v") = top3 ]]
  cat > "$n14762/top3/flake.nix" <<EOF
{
  inputs.library.url = "path:$n14762/library";
  outputs = { library, ... }: { inherit (library) v; };
}
EOF
  [[ $(nix eval --raw "$n14762/top3#v") = library ]]
)
