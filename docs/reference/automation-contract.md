# El contrato de una automatización

**Propósito.** Enunciar las seis cosas que toda automatización debe proveer, para que una
nueva sea consistente con las existentes sin que nadie tenga que leerlas.

**Alcance.** Cualquier módulo bajo `automations/`.

**Documentos relacionados**

- [architecture.md](architecture.md) — las capas donde se apoya un módulo
- [command-model.md](command-model.md) — el vocabulario de verbos y estados
- [../process/testing-strategy.md](../process/testing-strategy.md) — cómo se hace cumplir esto

Este contrato viene del repositorio hermano de Azure DevOps, y no es específico de ninguna
plataforma: aplica a cualquier herramienta que observe un sistema del que alguien depende.
Lo que cambió acá es el punto 4, porque no hay escritura.

## 1. Los seis puntos

| # | Requisito |
| --- | --- |
| 1 | Una **plantilla** de configuración completa y versionada, más el nombre activo al que se la renombra. |
| 2 | El archivo activo **excluido del control de versiones**, creado por *renombrado* y nunca por copia. |
| 3 | Un **JSON Schema** propio, validado en tiempo de ejecución. No documentación. |
| 4 | Un **punto de entrada único** `Invoke-<Módulo>.ps1` que expone `validate`, `inventory`, `plan` y `smoke`, y **ningún verbo que escriba**. |
| 5 | Una **guía** con propósito, configuración, comandos, permisos, salida y **rollback**. |
| 6 | **Tests** con fixtures que no contienen ningún dato real. |

`tests/automations/Automations.Tests.ps1` hace cumplir los seis. Un contrato que nada
verifica es un deseo.

## 2. Punto por punto

### 1 y 2 — La plantilla, y el renombrado

La plantilla está versionada y es completa: alguien la lee y ve la forma entera, con
valores de ejemplo. El archivo activo se produce **renombrándola**.

Renombrar en lugar de copiar no es una preferencia de estilo. El nombre activo es el que
`.gitignore` excluye; una copia invita a un archivo con un nombre *nuevo*, lleno de valores
reales, que Git rastrea encantado.

```text
jobs.example.json       ->  jobs.json        (excluido)
pipelines.example.json  ->  pipelines.json   (excluido)
issues.example.json     ->  issues.json      (excluido)
```

### 3 — Un schema que corre

Todo archivo de configuración apunta a su schema con una propiedad `$schema` relativa, y
`Get-JenkinsAsCodeConfiguration` la resuelve y valida antes de devolver.

Publicar un schema y no correrlo nunca es común y no vale nada: el schema documenta una
intención mientras el cargador acepta cualquier cosa, y los dos se separan sin que nadie lo
note. Acá `validate` valida de verdad, offline, así que una declaración malformada falla en
un segundo en lugar de a mitad de una corrida.

En PowerShell 5.1 no existe `Test-Json -Schema`, así que corre un validador reducido que
cubre tipo, `required`, `properties`, `additionalProperties`, `items`, `enum`, `const` y
`$ref` local. El resultado nombra el motor que corrió, para que un reporte nunca afirme más
cobertura de la que tuvo.

### 4 — Un punto de entrada, y ningún verbo que escriba

Un archivo, una superficie de comandos, un `-Command` con lista de valores cerrada.

| Debe exponer | Porque |
| --- | --- |
| `validate` | Verificación offline. Sin red, sin token. |
| `inventory` | Qué existe hoy, sin referencia a la declaración. |
| `plan` | La comparación que alguien revisa. |
| `smoke` | Plan más la checklist manual. |

Y **no** debe exponer `apply`, `reconcile`, `rename`, `delete` ni `remove`, ni declarar
ningún parámetro de confirmación. Ver
[ADR 0001](../adr/0001-read-only-by-construction.md).

Lo que tampoco debe pasar es un verbo genérico cargado de selectores que cambian lo que
significa. Un comando, una intención.

### 5 — Una guía, incluido rollback

Propósito, configuración campo por campo, comandos, los permisos que hacen falta, dónde va
la salida, y cómo se revierte lo hecho.

Rollback es la sección que la gente saltea y la que importa a las dos de la mañana. Está
permitido que diga *"no hay nada que revertir, y acá está por qué"* —que es el caso de las
tres automatizaciones de este repositorio— pero no está permitido que falte. El test del
contrato verifica que la palabra esté; un revisor verifica que signifique algo.

### 6 — Tests con fixtures inventados

Todo fixture es inventado. Un test que toma prestado un nombre de host, una ruta de job o
una credencial real convierte la suite en otro lugar del que se filtran datos, y los
archivos de test son el último lugar donde alguien mira.

Un test lleva el nombre de la falla que previene, no de la función que llama.

## 3. Reglas que cruzan los seis puntos

| Regla | Por qué |
| --- | --- |
| La declaración nombra un secreto, nunca contiene uno. | Es lo que hace commiteable toda la configuración. |
| Nada se escribe en el sistema observado. | Ver ADR 0001. |
| Toda operación lleva una razón escrita para quien la lee. | `pending` por sí solo no es revisable. |
| Una segunda corrida no cambia nada. | La idempotencia es el criterio de aceptación, no una optimización. |
| Lo que no se comparó no se reporta como `ok` sin decirlo. | Afirmar que algo coincide sin haberlo mirado es como un reporte se vuelve confiadamente falso. |

## 4. Cómo se agrega una

1. Crear `automations/<nombre>/` con `config/`, `schemas/` y, si hace falta, `examples/`.
2. Escribir la plantilla y su schema **primero**. La forma de la declaración es el diseño.
3. Escribir el punto de entrada. Reutilizar la fundación; no agregarle nada de dominio.
4. Registrar el módulo en `foundation/config/project-context.json`, bajo `automations`.
5. Escribir la guía como `README.md` del módulo y enlazarla desde `docs/README.md`.
6. Agregar la fila a la tabla del test del contrato.
7. Agregar la entrada en `CHANGELOG.md`.

El paso 3 es donde aparece la presión. Si la capa compartida parece necesitar un caso
especial para tu módulo, la lógica es de tu módulo. Ver
[ADR 0003](../adr/0003-shared-http-layer.md).
