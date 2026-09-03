# jira-inventory

**Propósito.** Resolver el id opaco de un campo personalizado de Jira a partir de su
nombre visible, y registrar el resultado de consultas JQL declaradas.

**Alcance.** Lectura de Jira. Nada más.

## Por qué existe

Un campo personalizado se direcciona en la API como `customfield_10042`, y en ningun
lugar de Jira aparece el nombre visible al lado de ese id. Un pipeline que necesita leer
un campo tiene que recibir el id de alguien que lo buscó a mano. Esto es esa búsqueda,
hecha repetible y revisable.

## Configuración

```text
config/issues.example.json  ->  config/issues.json
```

| Campo | Significado |
| --- | --- |
| `projectKeys` | Claves de proyecto en alcance. |
| `customFields[].key` | Nombre corto y estable, usado en los reportes. |
| `customFields[].displayName` | Nombre tal como se ve en Jira. La resolución ignora mayúsculas. |
| `customFields[].purpose` | Por qué importa este campo. Una declaración que nadie puede explicar es una que nadie puede retirar. |
| `queries[].jql` | La consulta. |
| `queries[].fields` | Campos a devolver por issue. |
| `queries[].expectation` | `any` registra la cantidad sin juzgarla; `non-empty` reporta `warning` si devuelve cero. |

Por qué `non-empty` vale la pena: un estado o componente renombrado **no hace fallar el
JQL**, hace que devuelva cero filas, en silencio. Así es como un pipeline que vigila una
cola deja de encontrar trabajo y nadie se entera.

## Comandos

```powershell
.\Invoke-JiraInventory.ps1 -Command validate
.\Invoke-JiraInventory.ps1 -Command inventory
.\Invoke-JiraInventory.ps1 -Command inventory -FieldName 'Etapa'
.\Invoke-JiraInventory.ps1 -Command plan
.\Invoke-JiraInventory.ps1 -Command smoke
```

`-FieldName` responde una pregunta sin editar la declaración. Las entradas ad hoc quedan
marcadas en el reporte, para que nunca parezcan estado declarado.

## Nombres duplicados son `blocked`, no una elección

Jira permite dos campos personalizados con el **mismo nombre visible**: pasa cada vez
que un campo se recrea en lugar de editarse, y el viejo sigue existiendo en otras
pantallas. Devolver el primero daría un id que funciona, se lee plausible y **pertenece
al campo equivocado**. Así que se reportan todos los candidatos y decide una persona.

## Por qué no escribe

Dos razones. Los `Jenkinsfile` de este parque ya comentan y transicionan issues por su
cuenta, con el plugin de Jira de Jenkins; un segundo escritor sobre el mismo workflow
produce transiciones dobles que después nadie puede atribuir. Y la pregunta que este
módulo existe para responder es una lectura.

## Permisos

| Permiso | Para qué |
| --- | --- |
| `Browse Projects` | Sobre cada proyecto en alcance. Sin él, Jira responde 404 igual que para un issue inexistente. |

El token va en `JIRA_API_TOKEN` y se saca de `id.atlassian.com`. Se emparea con el
**email** de la cuenta, no con un nombre de usuario: Jira Cloud rechaza un nombre de
usuario con un 401 que se lee como token equivocado.

## Salida

`artifacts/reports/jira-inventory-<comando>-<fecha>.json` y su resumen `.md`.
El reporte pasa por la redacción del módulo de reportes antes de escribirse.

## Rollback

**No hay nada que revertir.** No existe camino de código que escriba en Jira: ni
transiciones, ni comentarios, ni campos. Lo único que se crea son archivos bajo
`artifacts/`, borrables sin consecuencia.
