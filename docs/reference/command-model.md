# Modelo de comandos

**Propósito.** Definir cada verbo, cada estado y cada acción, y la regla que gobierna
cuándo puede ocurrir una escritura.

**Alcance.** El vocabulario que comparten las tres automatizaciones.

**Documentos relacionados**

- [architecture.md](architecture.md) — dónde vive el modelo de plan
- [ADR 0001](../adr/0001-read-only-by-construction.md) — por qué la escalera termina en `plan`

## 1. Verbos

| Verbo | Lee estado vivo | Escribe | Propósito |
| --- | --- | --- | --- |
| `validate` | No | No | La declaración contra su schema, más las invariantes que un schema no puede expresar. Sin red, sin token. |
| `inventory` | Sí | No | Qué existe hoy, sin referencia a la declaración. |
| `plan` | Sí | No | Clasifica cada operación. Es el artefacto que alguien revisa. |
| `smoke` | Sí | No | Plan más la checklist de verificación manual. |

**No hay `apply`.** Tampoco hay `reconcile`, `rename` ni ningún interruptor de
confirmación. No es una convención a recordar: es la ausencia de un camino de código, así
que no hay nada que agarrar por accidente. Un test del contrato lo verifica sobre el
`ValidateSet` de cada punto de entrada y sobre el código fuente de cada módulo.

## 2. Estados

Cinco valores, cerrados. Un estado de texto libre es como un plan se vuelve prosa que
nada puede hacer cumplir.

| Estado | Significa | Aparece en el resumen |
| --- | --- | --- |
| `ok` | El estado vivo ya coincide. Nada que hacer. | Se cuenta, no se lista. |
| `pending` | Hace falta un cambio. | Se lista. |
| `warning` | Vale que una persona lea la razón. | Se lista. |
| `protected` | Deliberadamente sin cambiar, para no destruir algo. | Se lista. |
| `blocked` | No se puede seguir con eso. | Se lista primero. |

### `pending` en un repositorio que no escribe

En el repositorio del que viene este modelo, `pending` significaba "hace falta un cambio y
es seguro hacerlo", y lo hacía `apply`.

Acá significa **hace falta un cambio y lo hace una persona**. El vocabulario se conserva
igual a propósito: quien lea un plan de este repositorio y uno del otro no tiene que
aprender dos idiomas. Lo que cambia es quién ejecuta, y eso lo dice esta línea una vez en
lugar de repetirlo en cada razón.

### `ok` contra `protected`

Los dos significan que nada va a cambiar, y la diferencia importa.

- `ok` — el estado vivo es lo que la declaración pide.
- `protected` — el estado vivo **no** es lo que la declaración pide, y se lo deja en paz
  deliberadamente.

### `ok` cuando algo no se comparó

Una propiedad opcional que la declaración no menciona produce acción `skip` con estado
`ok`, y la razón lo dice: *"No declarado, así que no comparado"*, con el valor vivo al
lado.

Esa distinción no es cosmética. `ok` afirma que se revisó el estado vivo y coincidía, y
afirmar eso sobre algo que nunca se comparó es como un reporte se vuelve confiadamente
falso.

### `blocked` detiene lo de ese recurso, no la corrida

Sin `apply`, `blocked` no puede "detener una aplicación". Significa: **no se pudo
determinar nada más sobre este recurso**, y por eso lo que sigue no se reporta.

Un job que no existe es `blocked`: las otras cinco comparaciones sobre él no tienen
sentido, y listarlas sepultaría el único hecho que importa. Un job ilegible es `blocked`
para ese job y **no** corta el recorrido de los demás: un reporte con cuarenta jobs más el
que falló es mucho más útil que una excepción.

## 3. Acciones

Qué le pasaría al recurso. También cerrado. Las que este repositorio usa:

| Acción | Significa |
| --- | --- |
| `exists` | Presente y ya correcto. |
| `update` | Una propiedad difiere de lo declarado. |
| `validate` | Una verificación sin escritura posible. |
| `resolve` | Una persona tiene que resolver una ambigüedad antes de que se pueda decir nada más. |
| `manual` | Deliberadamente no automatizado; lo hace una persona. |
| `skip` | Fuera de alcance para esta corrida, a propósito. |

`create`, `adopt`, `set`, `add`, `reconcile`, `rename` y `authorize` existen en el
vocabulario y **ninguna** se usa acá, porque todas describen una escritura.

## 4. La regla

**Toda operación lleva una razón escrita para quien la va a leer.** `pending` por sí solo
no es revisable: no dice qué difiere ni de qué.

**Una segunda corrida no cambia nada.** La idempotencia es el criterio de aceptación, no
una optimización. Declarado lo que `inventory` encontró, `plan` tiene que devolver cero
`pending`, y ese cero es la prueba de que el inventario y la comparación coinciden. Sin
él, ningún hallazgo posterior es creíble.
