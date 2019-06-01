# Cartesius
## Implementing Event Correlation Patterns with Algebraic Effects
## Or: Solving the Expression Problem for Joins

Cartesius is a DSL for defining expressive n-way joins over asynchronous
event sequences. Joins exists in different domains, e.g.,
stream-relational algebra, complex event patterns, (functional)
reactive programming and concurrent programming (join calculus).  With
Cartesius, we can define join variants in a uniform and structured manner,
solving the expression problem.  The workhorse are algebraic effects
and handlers, which we employ to interpret declarative join pattern
specifications in different ways.

### Versions

This repository features implementations of Cartesius in different languages:

* [Multicore OCaml](https://github.com/ocamllabs/ocaml-multicore) in the `ocaml/` subfolder (**actively developed**).

* [Koka](https://github.com/koka-lang/koka) in the `koka/` subfolder (**currently not maintained**).
Please check out the [`old` branch](https://github.com/bracevac/corrl/blob/old/koka/corrl/corrl/corrl.kk)
for the last working version.


## Contributors

* I thank [@namin](https://github.com/namin) for collaborating with me on the initial Koka prototype.

## References

**Versatile Event Correlation with Algebraic Effects** (ICFP 2018)
by Oliver Bračevac, Nada Amin, Guido Salvaneschi, Sebastian Erdweg, Patrick Eugster and Mira Mezini
([pdf](https://dl.acm.org/citation.cfm?id=3236762)).
