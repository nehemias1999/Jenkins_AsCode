# Alcance y límites

**Propósito.** Decir qué **no** hace este repositorio, y por qué cada hueco es una
decisión y no un olvido.

**Alcance.** Los límites. Lo que sí hace está en [capabilities.md](capabilities.md).

**Documentos relacionados**

- [ADR 0001](../adr/0001-read-only-by-construction.md) — la decisión detrás del límite principal
- [jenkins-notes.md](../reference/jenkins-notes.md) — el comportamiento de la API detrás de varios de estos

## 1. No escribe nada

| Qué | En su lugar |
| --- | --- |
| Crear o modificar un job | Se reporta la diferencia. La cambia una persona en la UI. |
| Habilitar o deshabilitar un job | Se reporta. |
| Borrar un job no declarado | Se preserva y se reporta. Lo que un job contiene —su historial, lo encolado— no está en la declaración, así que el radio de impacto no se puede predecir desde un plan. |
| Gestionar credenciales de Jenkins | Fuera de alcance. Un `GET` no devuelve el secreto, así que no hay forma de saber qué se reemplazaría. |
| Comentar o transicionar un issue de Jira | Los propios `Jenkinsfile` ya lo hacen. Dos escritores sobre el mismo workflow producen transiciones dobles que después nadie atribuye. |
| Cambiar una rama o el árbol de trabajo local | Sólo un `fetch` superficial, que agrega objetos y mueve `FETCH_HEAD`. Nada más. |

No hay verbo `apply`, ni interruptor de confirmación, ni función que envíe otra cosa que
`GET`. Es la ausencia del camino de código, verificada por un test.

## 2. No adivina cuando no puede saber

| Qué | Qué reporta |
| --- | --- |
| Un Branch Specifier con comodín (`**`, `feature/*`) | `blocked`. No nombra una rama, así que no hay un commit del que hablar. |
| Un Branch Specifier armado con una variable de build | `blocked`. Qué rama corre depende del build. |
| Dos campos de Jira con el mismo nombre visible | `blocked`, con los candidatos. Elegir el primero da un id que funciona y pertenece al campo equivocado. |
| Un pipeline con script inline | `warning`. No hay commit detrás, así que la deriva no es una pregunta contestable. |
| Un job que no existe | `blocked`, y las demás comparaciones sobre él no se reportan: listarlas sepultaría el único hecho que importa. |

Adivinar acá produciría una respuesta confiada y equivocada sobre qué código corre, que es
peor que ninguna respuesta.

## 3. Lo que reporta aproximado, lo dice

El **label de agente** de un pipeline se extrae del `Jenkinsfile` con una expresión
regular. Eso significa que también matchea un label dentro de un comentario, y que no
resuelve uno armado con una variable.

Se devuelven **todos** los labels encontrados y el reporte dice cuántos, en lugar de
afirmar uno. Es lo honesto para una expresión regular leyendo un lenguaje que no parsea.
La alternativa —parsear Groovy— no vale el costo para el valor que agrega.

## 4. La comparación de texto es de contenido, no semántica

`Compare-ScmText` distingue tres cosas: idéntico, diferencia sólo de espacios, y todo lo
demás. No entiende Groovy, así que un cambio que reordena dos líneas sin cambiar el
comportamiento se reporta como deriva.

Y los **comentarios cuentan como contenido**, a diferencia de cómo se compara un launcher
generado desde una plantilla. Acá los dos lados son el mismo archivo en dos momentos: si
cambió un comentario, alguien editó el archivo. Además, decidir si un `//` dentro de un
literal de cadena es un comentario no se puede hacer de forma confiable línea por línea,
así que la pregunta no se hace nunca.

## 5. No hay rollback, porque no hay nada que revertir

Lo único que se crea son archivos bajo `artifacts/`, borrables sin consecuencia. Y el
efecto del `fetch` superficial en el clon local: objetos nuevos y `FETCH_HEAD` movido, que
no cambia archivos ni ramas.

Si algún día se agrega escritura, esa sección tendrá que existir de verdad, y tendrá que
decir qué hacer cuando un `POST` de `config.xml` ya reemplazó el documento completo.

## 6. Necesita un clon local para comparar

`pipeline-drift` compara contra una copia de trabajo, declarada en `workingCopyRoot`. En un
agente limpio habría que clonar primero. Es la contrapartida de leer el SCM por `git` en
lugar de por la API de cada proveedor: ver
[ADR 0002](../adr/0002-git-cli-instead-of-provider-apis.md).

## 7. Los secretos ya expuestos no son alcance de esto

Las contraseñas en claro y commiteadas en los repositorios de pipelines —dentro de un
`Jenkinsfile`, de un script de build, o de un archivo `.env` sin ignorar— son un problema
real y urgente, y este repositorio no lo resuelve.

Están en el historial de git, así que borrar el archivo no alcanza: hay que rotarlas. Lo
que este repositorio sí hace es no agregar el problema: la configuración declara el
**nombre** de una variable de entorno, nunca su valor. Ver
[security-model.md](../reference/security-model.md).
