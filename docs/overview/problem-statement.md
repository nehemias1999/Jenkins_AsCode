# El problema

**Propósito.** Explicar qué pregunta no se puede responder hoy, y por qué eso importa.

**Alcance.** El porqué. Lo que este repositorio hace está en
[capabilities.md](capabilities.md).

## 1. La pregunta que nadie puede contestar

*¿El job que corre en producción está leyendo el commit que yo creo?*

Es la pregunta que importa la mañana después de un envío fallido, y hoy la única forma de
responderla es abrir la UI de Jenkins, mirar el Branch Specifier de cada job, y comparar a
mano contra lo que tiene el clon local.

## 2. Por qué no se puede

Tres hechos, cada uno inocuo por separado.

**El Branch Specifier no está en ningún archivo.** Vive en la configuración del job, en el
controller. `/api/json` no lo devuelve. Ningún repositorio lo registra. No existe un export
de la configuración de los jobs — no está desactualizado: no existe.

**El `Jenkinsfile` sí está en un repositorio, y eso engaña.** Los pipelines son
declarativos y viven en el SCM, así que da la impresión de que el circuito está *as code*.
Pero lo que está versionado es el *contenido* del pipeline, no *qué rama lee el job*. Las
dos mitades de la respuesta viven en lugares distintos y sólo una está bajo control de
versiones.

**Crear una rama no cambia lo que corre.** Un job configurado para leer `main` sigue
corriendo el código de `main`, por más ramas feature que existan. Hay que cambiar también
el Branch Specifier — en la UI. Y como esa mitad no está versionada, nada registra si se
cambió, ni cuándo, ni quién.

## 3. La forma de la falla

No hay mensaje de error.

Se edita una rama feature, se corre el job, y el job hace exactamente lo que hacía antes.
No falla: corre bien, con el código viejo. El síntoma es "el cambio no tuvo efecto", que se
investiga primero en el código, después en el ambiente, y último en la configuración del
job — que es donde estaba.

El plan de fases que motivó este repositorio tropieza con esto de frente: su primer paso
consiste en crear jobs temporales y cambiar Branch Specifiers a mano, sin ninguna forma de
verificar después qué quedó configurado.

## 4. Y hay una segunda falla, del mismo tipo

Los secretos del parque están en claro y commiteados: la contraseña de la herramienta de
envíos dentro de un `Jenkinsfile`, la del servidor de GeneXus dentro de un `.bat`, el token
de Jira en archivos `.env` que ningún repositorio ignora. No hay un solo uso del credential
store de Jenkins.

Eso no lo arregla este repositorio, y está fuera de su alcance. Pero es la misma clase de
problema: información crítica que vive donde nadie la revisa, y que nadie puede inventariar
porque no hay con qué.

## 5. Lo que se busca

Un repositorio que **declare** los jobs y, contra el controller vivo, responda tres cosas:

1. Qué jobs existen y cómo están configurados — el export que hoy no existe.
2. Qué commit alimenta realmente a cada uno.
3. En qué difieren de la declaración.

Sin escribir nada en Jenkins. Ver [ADR 0001](../adr/0001-read-only-by-construction.md).
