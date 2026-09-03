# Estrategia de tests

**Propósito.** Decir qué se prueba, qué no, y por qué.

**Alcance.** La suite automatizada y las verificaciones estáticas.

**Documentos relacionados**

- [../reference/automation-contract.md](../reference/automation-contract.md) — el contrato que la suite hace cumplir
- [../reference/architecture.md](../reference/architecture.md) — la forma del código que hace esto posible

## 1. Para qué sirve la suite

Los scripts de infraestructura atraen una excusa particular: *"esto sólo se puede probar de
verdad contra el sistema vivo"*. Es cierto de las peticiones y falso de todo lo que vale la
pena probar.

Las decisiones —qué escritura de rama significa qué, si una diferencia es cosmética o real,
si un nombre de campo resuelve a un id o a una ambigüedad— son funciones puras sobre datos.

Así que el punto de diseño vino primero: la lógica peligrosa se escribió como funciones
puras **para poder probarla offline**, y las llamadas a la API son una capa delgada
alrededor. La suite es consecuencia de esa forma, no un agregado.

## 2. Qué cubre

| Capa | Archivo |
| --- | --- |
| El parser de `config.xml`, incluido XML 1.1 y el rechazo del default de un Password | `tests/foundation/Jenkins.Jobs.ConfigXml.Tests.ps1` |
| Resolución de rama, fingerprints, veredictos de comparación, quoting de argumentos | `tests/foundation/Scm.Git.Tests.ps1` |
| URL, credencial Basic, política de retry, lectura de headers, rutas de carpeta | `tests/foundation/JenkinsAsCode.Http.Tests.ps1` |
| El contrato de las automatizaciones y la ausencia de todo camino de escritura | `tests/automations/Automations.Tests.ps1` |
| Las funciones puras de decisión de `pipeline-drift` | `tests/automations/PipelineDrift.PureFunctions.Tests.ps1` |
| La puerta de datos sensibles, incluido que no se salte lo que no debe | `tests/automations/SensitiveDataGate.Tests.ps1` |

Cada test lleva el nombre de **la falla que previene**, no de la función que llama. Y
varios llevan un comentario que dice qué produciría la implementación obvia, porque eso es
la información que se pierde primero.

## 3. Cómo se corre

```powershell
.\scripts\Invoke-Tests.ps1
```

Tres verificaciones en orden creciente de costo: análisis estático con PSScriptAnalyzer, la
suite con Pester 5 o superior, y el escaneo de datos sensibles. La integración continua
corre el mismo comando, así que no hay una segunda definición de "pasa".

`Pester` y `PSScriptAnalyzer` hacen falta **sólo** para los tests. Ninguna automatización
los necesita.

## 4. Dos cosas que la suite hace y no son habituales

**Verifica ausencias.** El test del contrato hace grep sobre el código fuente exigiendo que
**no** aparezca `apply` en ningún `ValidateSet`, que **no** haya un `-Method Post`, que
**no** exista un `git checkout`, y que `Invoke-WebRequest` figure en **un solo archivo**.
Una regla que sólo está escrita en un documento es una regla que el próximo commit puede
romper sin que nada avise.

**Prueba las reglas de un módulo sin moverlas a código compartido.** Las funciones de
decisión de `pipeline-drift` se extraen del punto de entrada con una expresión regular y se
cargan con dot-sourcing. Las reglas de una automatización viven en esa automatización
([ADR 0003](../adr/0003-shared-http-layer.md)), y así igual se prueban aisladas, en lugar de
promoverlas a un módulo compartido sólo para poder testearlas.

**Corre los propios comandos.** El test que verifica que cada plantilla es ejecutable
invoca el punto de entrada real con `-Command validate`. `validate` promete que una
declaración malformada falla en un segundo en lugar de a mitad de una corrida; ese test es
la promesa ejercida.

## 5. Qué no cubre

No hay tests contra un controller vivo. Las funciones que hacen peticiones son adaptadores
delgados, y probarlas exigiría un Jenkins de prueba con jobs preparados: mucha
infraestructura para cubrir código que casi no toma decisiones.

Lo que reemplaza eso es la checklist manual del verbo `smoke`, que dice qué mirar en la UI
después de una corrida, incluido un paso que **exige provocar una deriva a propósito** y
comprobar que el veredicto cambia. Un comparador que nunca reportó una diferencia no se ha
demostrado que compare.

## 6. Bugs que la suite encontró mientras se escribía

Vale registrarlos, porque son la evidencia de que la suite hace algo:

- El parser fallaba en **todos** los `config.xml` reales, porque Jenkins escribe una
  declaración XML 1.1 y .NET parsea 1.0. Apareció en la primera corrida contra un fixture
  realista.
- `New-JenkinsJobPath` rechazaba un job llamado `Job`. La guarda que lo hacía partía de una
  premisa falsa —que un segmento llamado `job` sería ambiguo— y como PowerShell compara sin
  distinguir mayúsculas, se llevaba puesto un nombre corriente. La guarda se eliminó.
- `ConvertTo-ProcessArgumentString` no aceptaba un argumento vacío, porque la validación por
  defecto de un parámetro `[string[]]` obligatorio lo rechaza.

## 7. Los fixtures son inventados

Sin excepción. Un fixture que tomara prestado un nombre de host o una ruta de job real
convertiría la suite en otro lugar del que se filtran datos, y los archivos de test son el
último lugar donde alguien mira.
