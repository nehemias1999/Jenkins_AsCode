# Notas de comportamiento de Jira

**Propósito.** Registrar el comportamiento de la API de Jira que hizo falta descubrir,
con el síntoma que produce.

**Alcance.** Jira Cloud y Data Center, en lectura. Las de Jenkins están en
[jenkins-notes.md](jenkins-notes.md).

**Documentos relacionados**

- [../../automations/jira-inventory/README.md](../../automations/jira-inventory/README.md) — la guía del módulo
- [troubleshooting.md](../guides/troubleshooting.md) — el síntoma primero

---

## 1. El endpoint de búsqueda cambió, y el viejo devuelve 404

**El comportamiento.** En Jira Cloud, API v3, el clásico `/rest/api/3/search` fue
**removido**. El reemplazo es `/rest/api/3/search/jql`, que además pagina con un
`nextPageToken` opaco en lugar de `startAt`. En Server y Data Center, v2, `/search`
sigue siendo correcto y pagina con `startAt`.

**El síntoma.** Un 404 en la búsqueda, que se lee como un problema de permisos sobre el
proyecto.

**Lo que hace este repositorio.** `Search-JiraIssue` elige el endpoint y el esquema de
paginación según `jira.apiVersion` del contexto de proyecto, así que el llamador escribe
una sola llamada.

## 2. Dos campos personalizados pueden tener el mismo nombre visible

**El comportamiento.** Jira lo permite. Pasa cada vez que un campo se recrea en lugar de
editarse: el viejo sigue existiendo, referenciado desde otras pantallas.

**El síntoma.** Ninguno. Una función que devuelve el primer match resuelve el nombre a un
id que funciona, se lee plausible y pertenece al campo equivocado. El pipeline lee
siempre vacío y nadie sospecha del id.

**Lo que hace este repositorio.** `Find-JiraFieldByName` devuelve **todos** los matches,
y `jira-inventory` reporta `blocked` con la lista de candidatos cuando hay más de uno.
Decide una persona.

## 3. Un estado renombrado no hace fallar el JQL

**El comportamiento.** Un JQL que nombra un estado, componente o campo que ya no existe
con ese nombre no devuelve error: devuelve **cero filas**.

**El síntoma.** Un pipeline que vigila una cola deja de encontrar trabajo. No hay error,
no hay alerta, y la cola se llena.

**Lo que hace este repositorio.** Una consulta se declara con `expectation`. Con
`non-empty`, cero resultados se reporta como `warning` — porque las dos causas posibles
(no hay trabajo, o el JQL quedó viejo) no se distinguen desde acá y las dos merecen que
alguien mire.

## 4. El token se empareja con el email, no con el nombre de usuario

**El comportamiento.** La autenticación Basic de Jira Cloud espera
`email:api_token`. Un nombre de usuario en lugar del email se rechaza.

**El síntoma.** Un 401, que se lee como token equivocado y manda a buscar al lugar
incorrecto.

**Lo que hace este repositorio.** El mensaje del 401 dice exactamente esto.

## 5. Un 404 no prueba que el issue no exista

**El comportamiento.** Jira responde 404 tanto para un issue que no existe como para uno
que la cuenta no tiene permiso de ver.

**El síntoma.** Un reporte que afirma que un ticket fue borrado cuando lo que falta es
`Browse Projects`.

**Lo que hace este repositorio.** La ayuda de `Get-JiraIssue` lo dice, y nada en el
código afirma ausencia a partir de un 404.
