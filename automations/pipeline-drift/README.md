# pipeline-drift

**Propósito.** Responder, para cada job de Jenkins, **qué commit lo alimenta realmente**
y si la copia local es ese mismo código.

**Alcance.** La unión de tres fuentes. La configuración del job en sí es de
[job-inventory](../job-inventory/README.md).

## Por qué existe

Ninguna de las tres fuentes alcanza sola:

1. El job vivo dice qué repositorio y qué rama lee. Sólo `config.xml` lo tiene.
2. El remoto dice a qué commit apunta esa rama ahora.
3. La copia local dice qué está mirando la persona que trabaja.

**La trampa que esto detecta:** un job configurado para leer `main` sigue corriendo el
código de `main`, por más ramas feature que existan. Crear una rama y editarla no
cambia nada de lo que corre hasta que también se cambia el Branch Specifier del job — y
como el especificador vive en la UI de Jenkins, ningún archivo del repositorio registra
si se cambió. Es una falla silenciosa, sin mensaje de error.

## Configuración

```text
config/pipelines.example.json  ->  config/pipelines.json
```

| Campo | Significado |
| --- | --- |
| `workingCopyRoot` | Directorio que contiene los clones, relativo a la raíz del repo o absoluto. |
| `pipelines[].key` | Nombre corto y estable. |
| `pipelines[].jobPath` | Ruta visible del job en Jenkins. |
| `pipelines[].workingCopy` | Nombre del directorio bajo `workingCopyRoot`. |
| `pipelines[].remoteName` | Remoto de git a consultar. Por defecto `origin`. |

La rama, el commit y la ruta del script **no se declaran**: se leen del job vivo.
Declararlos sería afirmar justamente lo que este módulo existe para verificar.

## Comandos

```powershell
.\Invoke-PipelineDrift.ps1 -Command validate
.\Invoke-PipelineDrift.ps1 -Command inventory
.\Invoke-PipelineDrift.ps1 -Command plan
.\Invoke-PipelineDrift.ps1 -Command plan -PipelineKey example-pipeline
.\Invoke-PipelineDrift.ps1 -Command smoke
```

## Cómo lee el SCM

Por la línea de comandos de `git`, no por la API del proveedor. La API REST de GitHub
resolvería la consulta, pero obligaría a declarar un PAT propio en la configuración y a
rotarlo. `git` ya es prerrequisito, ya esta autenticado en la estación, y responde igual
contra cualquier remoto —github.com, GitHub Enterprise u otro—: un solo camino de código,
y **ningún token de SCM acá**.

## Qué toca localmente

Un `fetch` superficial, cuando el commit que el job lee no esta en el clon. Eso **agrega
objetos y mueve `FETCH_HEAD`**. No hace checkout, no mueve ninguna rama, no toca el árbol
de trabajo y no mergea. Correrlo sobre el clon de alguien deja sus archivos y su rama
actual exactamente como estaban: no existe camino de `checkout` ni de `pull` en
`Scm.Git`, y un test del contrato lo verifica.

## Veredictos

| Veredicto | Significado |
| --- | --- |
| `identical` | La copia local es el código que el job correría. |
| `cosmetic` | Mismo código; difiere sólo en espacios finales o lineas vacías. |
| `drift` | La copia local no es el código que el job correría. |

Los comentarios cuentan como contenido, a diferencia de cómo se compara un launcher
generado. Aca los dos lados son el **mismo archivo en dos momentos**: si cambió un
comentario, alguien editó el archivo. Y decidir si un `//` dentro de un literal de
cadena es un comentario no se puede hacer de forma confiable línea por línea, asi que la
pregunta no se hace nunca.

## Permisos

Los mismos que `job-inventory`, incluido **`Job/ExtendedRead`**. Además, acceso de
lectura de `git` a los remotos de los clones declarados.

## Salida

`artifacts/reports/pipeline-drift-<comando>-<fecha>.json` y su resumen `.md`.

El reporte lleva **fingerprints SHA-256, nunca contenido del `Jenkinsfile`**. En este
parque esos archivos contienen credenciales en claro, y el reporte es justamente el
artefacto que se adjunta a un ticket.

## Rollback

**No hay nada que revertir en Jenkins ni en el SCM.** Este módulo no escribe en ninguno
de los dos.

Lo único que persiste fuera de `artifacts/` es el efecto del `fetch` superficial en el
clon local: objetos nuevos y `FETCH_HEAD` movido. Nada de eso cambia archivos ni ramas.
Si molesta, `git gc --prune=now` recupera el espacio; no hace falta para nada más.
