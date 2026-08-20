# Portable declarative documents

This is the portable-document capability from issue
[#34](https://github.com/ahojukka5/Episteme.jl/issues/34). It is an
explicit interchange subset, not the default persistence path and not a
restriction on live `SemanticNode` trees (issue
[#12](https://github.com/ahojukka5/Episteme.jl/issues/12)).

Episteme supports two persistence capabilities:

1. **Julia-native persistent** — JLD2-backed working archives may store
   rich safe Julia values. That path is later AH5 work and is unchanged
   here.
2. **Portable declarative** — fail-closed capture of authored intent for
   interchange, Git-diffable views, generic inspection, and replay
   without arbitrary runtime types.

JLD2 type metadata is not a scientific schema. JLD2 `Upgrade` is not a
semantic migration.

## Live trees vs portable documents

A `SemanticNode` attribute may still hold any Julia value. That tree is
not automatically portable.

```julia
live = SemanticNode(:payload; dual = DualLike(1.4, 1.0))  # legal live tree
validate_portable(live)   # fails :unsupported_portable_value
capture_portable(DocumentId("doc-1"), live)  # throws
```

`capture_portable` either returns a `PortableSemanticDocument` or fails
with node/attribute diagnostics. It does not fall back to `show` text,
`eval`, closures, or Julia AST replay.

## Portable universe

Supported leaves:

- `Bool`, `Int` (from portable integers), `Float64`, `String`, `Symbol`,
  `nothing`
- `NodeRef`
- tuples, named tuples, arrays, and `Dict`s of portable values
  (`Dict` keys must be `Symbol` or `String`)
- `PortableEncoded` values from a registered codec

`Float32`, `Char`, functions, and unregistered custom structs fail
closed. Dictionary insertion order is not semantic: capture sorts keys
so canonical form and `portable_sexpr` are stable.

## Codecs

Domain packages may register a portable representation without making
the live type the interchange format:

```julia
import Episteme: portable_encode, portable_decode

portable_encode(x::MyMaterial) =
    (kind = Symbol("example/material"), data = (; name = x.name, modulus = x.modulus))

portable_decode(::Val{Symbol("example/material")}, data) =
    MyMaterial(data.name, data.modulus)
```

Generic inspection sees `PortableEncoded`. `restore_semantic(doc;
decode=true)` reconstructs the Julia value only when a codec is present.
Reload from `to_namedtuple` / `from_namedtuple` never calls `eval`.

## Document shape

`PortableSemanticDocument` holds a `DocumentId`, `episteme/document`
`SchemaRef`, fragment roots, and optional metadata. Fragments keep
package-qualified kinds and cross-fragment `NodeRef`s. Episteme does not
resolve references or compile a `Plan` here; `Plan.document_id` is the
later link.

`portable_sexpr` is a human-readable view for inspection and diffs. The
structured document is authoritative. The S-expression is not a loader
and is not arbitrary-runtime replay.

## What this is not

- a requirement that every live tree be portable
- a replacement for JLD2 working-archive persistence
- domain execution order or `NodeRef` resolution
- serialization of every Julia object
- `sexpr` on live `SemanticNode` trees
