# Encargo: auditoría profunda del motor de trayectos (RAPTOR)

> Prompt para Claude Code (Opus 5). Pégalo entero como primer mensaje en una sesión abierta
> en la raíz del repo. Está escrito para ser autosuficiente: no hace falta contexto previo.
>
> Documento hermano: `AUDITORIA-BUSCADOR-PROMPT.md`, que audita el buscador. Los dos motores
> son independientes y se auditan por separado a propósito.

---

Eres un auditor de código especializado en algoritmos de planificación de transporte público
(RAPTOR, CSA, Pareto multicriterio), Swift 6 y verificación de código numérico. Vas a auditar
**una sola cosa** de este proyecto: el **motor de trayectos** — el planificador RAPTOR y toda
la cadena que va desde el GTFS importado hasta la lista de alternativas ordenadas.

Esta tarea implica razonamiento en varios pasos y sobre invariantes matemáticas, no solo
lectura de código. Piénsala con cuidado antes de escribir nada.

**No modifiques ningún fichero del repositorio.** El entregable es un informe. **Sí** debes
escribir y ejecutar código de verificación desechable — es la parte central del encargo, no un
extra — pero ponlo en `/tmp` o en un directorio fuera del repo, o en un fichero de test que
borres al terminar. No toques el código de producción ni los tests existentes.

---

## 1. Qué es este proyecto

App iOS nativa en SwiftUI para el transporte público de Vigo (autobuses de Vitrasa). Proyecto
personal, sin distribución, sin telemetría. iOS 18 mínimo, Swift 6 con
`SWIFT_STRICT_CONCURRENCY: complete`, `swiftLanguageMode(.v6)` en el paquete.

- **`VigoCore/`** — paquete SwiftPM, sin UIKit ni MapKit, con toda la lógica y la persistencia
  (GRDB 7 sobre SQLite). ~280 tests. **El motor entero vive aquí**, y eso es deliberado: se
  verifica con `swift test` en el Mac, sin simulador.
- **`App/ILoveVigoRoutes/`** — la app SwiftUI. Solo consume el resultado del motor.

Datos: GTFS de Vitrasa importado semanalmente. **El feed publicado solo cubre siete días**, lo
cual es una restricción de diseño real y no un accidente. Escala del feed real: 1.149 paradas,
59 rutas (43 con servicio), ~137.000 `stop_times`, ~3.800 viajes. El importador borra y
reescribe las tablas estáticas en cada refresco.

Documentación que debes leer antes de abrir código, en este orden:

1. `README.md` — decisiones sobre el feed y la ventana de 7 días.
2. `ESTADO.md`, **la sección «Fase 3 — Planificador de rutas» completa**. Son los once pasos
   con los que se construyó este motor, incluida la bitácora de los bugs que aparecieron y
   cómo se cazaron. Es el documento más importante de este encargo.
3. `ESTADO.md`, **la sección «Fase 10 — Criterio de ordenación de alternativas»**, que
   reescribió la selección y el corte de alternativas.
4. `PLAN-FASES-8-13.md` §10 — el razonamiento detrás de Fase 10.
5. `DATA-SOURCES.md` — verificación de las fuentes, y en particular la validación estructural
   del feed (integridad referencial, formatos de hora, secuencias monótonas).

El proyecto documenta sus decisiones **dentro del código**, en comentarios largos que explican
el *porqué* y que a menudo declaran una invariante o una precondición explícita. Trátalos como
parte del artefacto: **un comentario que declara una precondición te da exactamente el criterio
con el que juzgar el código, y un comentario que ya no describe lo que el código hace es un
hallazgo por sí mismo.**

## 2. Qué es «el motor de trayectos»

Todo el camino desde las tablas del GTFS importado hasta `[Journey]` ordenadas y recortadas.

**Fuera de alcance, no lo audites:** el buscador (`MapSearchSheet`, `searchStops`,
`AddressSearch*`), el importador GTFS y su parser salvo los campos que el motor lee, el tiempo
real (`Network/`, `ArrivalsService`) — con la excepción de `FirstBoardingMatch`, que sí entra —,
el dibujo del mapa, Favoritas, el trayecto activo y la Fase 13. Si tropiezas con algo grave
fuera de alcance, anótalo en una sección aparte de dos líneas y sigue.

### 2.1 Inventario de ficheros (audítalos todos, no solo los que menciono como ejemplo)

**El motor, en `VigoCore/Sources/VigoCore/Planner/`:**

| Fichero | Qué es |
|---|---|
| `RaptorEngine.swift` | **El núcleo.** Función pura `(Timetable, RaptorQuery) -> RaptorResult`. Rondas, poda por objetivo, búsqueda binaria del viaje alcanzable, un salto a pie por ronda |
| `Timetable.swift` | La instantánea inmutable: arrays planos CSR en `Int32`, eje temporal, incidencia inversa, footpaths, procedencia |
| `TimetableBuilder.swift` | Construye la instantánea: pliega tres días de servicio sobre un eje, agrupa viajes en patrones y **los separa por adelantamiento** — la precondición de la búsqueda binaria del motor |
| `TimetableStore.swift` | Actor con caché LRU de 3, clave (día ancla, `feedStatus.importedAt`) |
| `JourneyReconstruction.swift` | Recorre los `parent` hacia atrás, hace el **ajuste hacia atrás** al viaje más tardío viable, y elige el frente de Pareto de bajada (`egressCandidates`, `trim`) |
| `JourneyShortlist.swift` | `undominated` (dominancia de cuatro ejes) y `cut` (recorte por rotación entre criterios) |
| `JourneyOrdering.swift` | Los tres criterios de ordenación y sus desempates |
| `JourneyPlanner.swift` | La fachada: resuelve lugares, comprueba ventana y servicio, hace hasta `maxDepartureScans` pasadas de RAPTOR, decide entre `.journeys`, `.walkOnly` y los seis fallos |
| `WalkModel.swift` | Metros→segundos, y el barrido en latitud que genera los footpaths |
| `PlannerOptions.swift` | Los trece números de política, cada uno con su justificación escrita |
| `Journey.swift`, `Place.swift` | Los valores de salida |
| `PlanOutcomeMessage.swift` | La traducción de los ocho `PlanOutcome` a texto |
| `FirstBoardingMatch.swift` | El cruce con tiempo real del primer embarque — **anota, nunca decide** |

**Dependencias del motor, fuera de `Planner/`:**

| Fichero | Qué mirar |
|---|---|
| `Persistence/TransitRepository.swift` | `nearbyStops`, `allStops`, `activeServiceIDs(on:)`, `feedStatus`, `calendar`, `haversineMetres` |
| `Persistence/AppDatabase.swift` | El esquema y los tipos de columna de `stopTime` (`stopSequence`, `arrival`, `departure`) y de `trip`; los índices que la consulta del builder usa |
| `Model/ServiceTime.swift`, `Model/Identifiers.swift` | El tipo de hora del feed y `ServiceDate`, incluida su aritmética de días y su zona horaria |
| `MapFlow/MapNavigationState.swift` | Solo `visibleJourneys`, `ordering`, `visibleLimit`, `selectedAlternative` y `planningFinished` — el consumidor del motor |

**Tests existentes del motor** (`VigoCore/Tests/VigoCoreTests/`):
`RaptorEngineTests`, `BruteForceReference` + `BruteForceReferenceTests`, `PlannerFixtures`,
`JourneyReconstructionTests`, `JourneyPlannerTests`, `JourneyAlternativesTests`,
`JourneyOrderingTests`, `JourneySummaryTests`, `JourneyWalkSegmentsTests`,
`EgressCandidatesTests`, `TimetableBuilderTests`, `TimetableStoreTests`, `WalkModelTests`,
`PlanOutcomeMessageTests`, `FirstBoardingMatchTests`, `RealFeedIntegrationTests`.

## 3. Invariantes que el motor se ha impuesto

Úsalas como criterio. Una violación es un hallazgo aunque el código «funcione» y aunque los
tests estén en verde.

1. **El motor es una función pura.** Sin reloj, sin red, sin base de datos dentro de
   `RaptorEngine`. Es lo que lo hace contrastable contra una referencia exhaustiva.
2. **El tiempo real nunca decide la ruta, solo la anota.** Decisión explícita de la Fase 3.
3. **Optimalidad, no plausibilidad.** El modo de fallo real de este algoritmo es devolver
   respuestas creíbles pero subóptimas, que ningún test de ejemplo caza. El proyecto ya se
   quemó con esto: lee en `ESTADO.md` el paso 4/11 de la Fase 3.
4. **Los viajes de un patrón no se adelantan entre sí.** Es la precondición de las dos
   búsquedas binarias (`RaptorEngine.earliestTrip` y `JourneyReconstruction.latestTrip`) y la
   garantiza `TimetableBuilder.nonOvertakingGroups`. Si esa garantía tiene un agujero, las dos
   búsquedas devuelven basura silenciosamente.
5. **Un solo salto a pie por ronda.** Sin punto fijo. La desigualdad triangular lo hace seguro,
   y encadenar caminatas convertiría un transbordo en una caminata de 900 m.
6. **Solo la etiqueta de la ronda anterior puede embarcar.** Llegar y salir en la misma ronda
   sería montar dos vehículos al precio de uno.
7. **Determinismo.** Empates resueltos igual en cada ejecución; dos construcciones del mismo
   feed producen arrays idénticos byte a byte. Una respuesta ambigua sería intesteable.
8. **Cortar antes de ordenar es un error.** Fase 10 entera existe por esto: recortar la lista
   por llegada antes de aplicar el criterio del usuario decide la respuesta por un criterio que
   nadie eligió. **Comprueba que ese principio se respeta en cada punto de la cadena donde hay
   un recorte, no solo en el que Fase 10 arregló.**
9. **Distinguir «no tengo datos» de «no hay servicio».** El feed cubre siete días; confundir
   los dos hechos es exactamente el tipo de respuesta silenciosamente equivocada que este
   proyecto descarta por diseño.
10. **Las caminatas son estimaciones en línea recta por un factor de rodeo, y la UI lo dice.**
    No hay grafo peatonal. Redondeo siempre hacia arriba, para no prometer un autobús que no se
    puede coger.

## 4. Ejes de la auditoría — cúbrelos todos, para todos los ficheros del inventario

No te limites al primero ni a los que te resulten más evidentes. Recorre los diez ejes
completos contra **cada** fichero del §2.1 en el que apliquen.

**A. Corrección algorítmica de `RaptorEngine`.** Verifica que cada paso hace lo que RAPTOR
define: la construcción de la cola de patrones y la posición de arranque, el barrido hacia
delante, la condición de mejora, la condición de embarque y de salto a un viaje anterior, la
relajación de footpaths, la poda por objetivo y la condición de parada. Interesan
especialmente: si la poda por `targetBest` puede descartar una etiqueta que aún llevaría a una
alternativa **con menos transbordos** (poda por llegada frente a frente de Pareto de dos
dimensiones); si `bestArrival` como poda local puede eliminar una etiqueta necesaria en una
ronda posterior; si `ready` distingue correctamente los tres orígenes de holgura (acceso, mismo
andén, caminata); y si la instantánea `rideArrival` cierra de verdad el agujero que
`ESTADO.md` documenta en el paso 4/11.

**B. Las precondiciones de las búsquedas binarias.** `earliestTrip` y `latestTrip` solo son
correctas si la ordenación de los viajes de un patrón es idéntica en todas las posiciones.
Audita `nonOvertakingGroups` como el argumento matemático que es: la afirmación de que
«comparar contra el último del grupo basta», el criterio de `overtakes` (¿qué pasa con horas
iguales? ¿con arrival y departure discrepando?), el orden previo por `departures[0]`, y si un
first-fit puede dejar un grupo en el que un miembro adelanta a otro no adyacente. Construye
contraejemplos si crees que existe uno.

**C. El eje temporal, los días y los husos.** El plegado de tres días de servicio, el
desplazamiento calculado como diferencia real entre medianoches, el filtro `onlyPastMidnight`,
los viajes que cruzan las 24:00 y los que cruzan el cambio de hora de octubre y de marzo. La
zona horaria efectiva en `ServiceDate`, `repository.calendar` y `axisSeconds`. Un viaje a las
`25:10` un viernes. Una consulta a las 23:50. Comprueba también qué pasa en el borde de la
ventana de siete días del feed.

**D. Aritmética y tipos.** El motor usa `Int32` y operadores envolventes (`&+`, `&-`, `&*`) en
todas partes. Para **cada** uso, di si el desbordamiento es imposible por construcción, y si lo
es, si hay algo que lo documente o lo compruebe. Mira en particular `RaptorResult.unreached ==
Int32.max` participando en sumas, el `targetBest` inicial, el `exitKey` de
`JourneyReconstruction`, las conversiones `Int` ↔ `Int32` al leer de SQLite, y los redondeos de
`axisSeconds`/`WalkModel`.

**E. Reconstrucción y ajuste hacia atrás.** El recorrido de los `parent`: si puede ciclar, si
puede quedarse sin terminar, si su condición de parada por `currentRound` es correcta para las
tres formas de `RaptorParent`. El ajuste hacia atrás: si el viaje elegido puede volverse
infactible respecto al tramo anterior, si el `?? ride.trip` de reserva es alcanzable de verdad
o es código muerto, y si la propagación del límite resta la holgura correcta en cada uno de los
tres tipos de hueco. La coherencia entre `Journey.departure`, `Journey.arrival`,
`Journey.duration` y las horas de los tramos que la componen.

**F. Selección, dominancia y recorte.** Aquí es donde vive la Fase 10, y donde una regresión no
rompe nada visiblemente — solo devuelve peores respuestas. Audita: si `egressCandidates`
produce de verdad el frente de Pareto de (llegada, caminata final) y si `trim` desde los dos
extremos conserva ambos óptimos para cualquier `limit`; si la relación de `undominated` es una
dominancia válida (irreflexiva, transitiva, sin que un empate elimine a los dos); si el eje
`departure` de la dominancia significa lo mismo que el `earliestBoarding` de la ordenación, o
si son dos nociones distintas de «sale antes» conviviendo; si `cut` por rotación garantiza de
verdad que el óptimo de cada criterio sobrevive; y **si hay algún recorte anterior en la cadena
que ya haya decidido por llegada antes de llegar aquí**. Ese último punto es la pregunta más
valiosa de este eje: recórrela extremo a extremo, desde `alternatives` hasta `visibleJourneys`.

**G. La fachada y los ocho desenlaces.** El orden de las comprobaciones en `JourneyPlanner.plan`
y si un desenlace puede enmascarar a otro más informativo. El bucle `scan`: su terminación, si
la siguiente pasada encuentra de verdad un autobús posterior, si la condición de corte por
`maxCandidates` es la correcta, y si acumular y recalcular `ranked` dentro del bucle tiene
efectos que no se ven. La decisión `walkOnly` frente a `noJourneyFound` frente a `journeys`.
Casos límite: origen igual a destino; los dos en la misma parada; cero paradas cerca de uno de
los dos; un origen que también es una salida válida.

**H. Rendimiento y asignaciones.** El presupuesto declarado es <1 s y lo medido son 40 ms en
frío contra el feed real, así que **no busques microoptimizaciones: busca lo que escala mal**.
Cuenta asignaciones por ronda (los arrays reconstruidos, los diccionarios), el coste de hashear
`Journey` — que contiene `intermediateStops: [Stop]` con nombres — dentro de un `Set`, la
complejidad de `undominated` y de `cut`, y el coste de las hasta cuatro pasadas de `scan`.
Mide, no estimes: hay un feed real disponible y un test de tiempos que ya lo hace. Aparte,
audita `TimetableStore` como actor: qué trabajo bloqueante se ejecuta sobre su ejecutor y
durante cuánto, y si la afirmación de que no hace falta bookkeeping de `inFlight` sigue siendo
cierta.

**I. Concurrencia y Swift 6.** El `Task.detached` de `JourneyPlanner.plan` y qué cruza la
frontera. La conformidad `Sendable` de `Timetable` (un valor grande copiado o compartido por
CoW). El precalentamiento en `AppEnvironment`. Cualquier `@unchecked Sendable` o supuesto de
aislamiento sin justificación escrita que resista.

**J. Verificación existente: ¿qué NO cazaría?** Para cada test del §2.1, decide si pasaría
igual con el código roto. Esta parte no se hace leyendo: se hace mutando. Ver §5.

## 5. Método obligatorio: contraste diferencial y mutación

Este proyecto ya usa este método y lo documenta; tu trabajo es aplicarlo más a fondo, no
inventarlo. **Estas cuatro cosas no son opcionales.**

**1. Amplía el contraste aleatorizado.** `BruteForceReferenceTests` compara `RaptorEngine`
contra una referencia exhaustiva sobre 200 instancias aleatorias con semilla fija. Ejecútalo
con muchas más instancias y con más semillas, y **amplía el generador de instancias** para que
produzca formas de red que hoy no genera: patrones con viajes que se adelantan, footpaths
densos, redes con paradas gemelas, horizontes muy cortos, accesos y salidas solapados, viajes
con horas iguales, días con cero servicio. Si el generador no puede producir una forma que
importa, eso ya es un hallazgo sobre la cobertura de la suite. Reporta cualquier discrepancia
con la instancia mínima que la reproduce.

**2. Extiende el contraste más allá del motor.** Hoy la referencia solo compara etiquetas de
llegada. La reconstrucción, el ajuste hacia atrás, la dominancia y el recorte **no tienen
oráculo**. Escribe uno: para instancias pequeñas, enumera por fuerza bruta todos los trayectos
door-to-door posibles y comprueba las propiedades que el diseño promete — que la alternativa
devuelta es óptima en llegada para su número de transbordos; que el ajuste hacia atrás produce
la salida más tardía posible sin perder ninguna conexión; que el óptimo de cada uno de los tres
criterios está entre las candidatas devueltas. Di explícitamente qué propiedades pudiste
comprobar y cuáles no.

**3. Muta el código de producción y comprueba que la suite lo nota.** Aplica al menos estas
mutaciones, una a una, ejecutando `swift test` con cada una y revirtiéndola después: invertir
un `<` por `<=` en cada condición de mejora y de embarque; usar la ronda actual en vez de la
anterior al embarcar; eliminar la instantánea `rideArrival`; quitar la separación por
adelantamiento; desactivar el ajuste hacia atrás; sustituir `trim` desde los dos extremos por
`prefix(limit)`; sustituir `cut` por rotación por `prefix(limit)` sobre el orden por llegada;
quitar el eje de caminata de `undominated`; cambiar el desplazamiento entre días por 86400
fijo. **Para cada mutación, reporta qué tests fallaron y cuáles no.** Una mutación que nadie
caza es un hallazgo de la categoría `testabilidad`, con la misma dignidad que un bug.

**4. Usa el feed real.** `RealFeedIntegrationTests` se activa con
`VIGO_GTFS_ZIP=/ruta/gtfs_vigo.zip swift test`. Si el fichero no está disponible en el entorno,
dilo de forma destacada al principio del informe y marca como **no verificado** todo lo que
dependiese de él — no lo sustituyas por razonamiento presentado como medida. Si sí está, úsalo
para los tiempos del eje H y para consultas reales de extremo a extremo por la ciudad.

## 6. Reglas del informe

**Cobertura, no precisión.** Reporta **cada** problema que encuentres, incluidos los que no
tengas claros y los que consideres de baja severidad. No filtres por importancia ni por
confianza en esta etapa. Si dudas entre reportar y callar, reporta. Un hallazgo menor con la
etiqueta «confianza baja» vale más que un hallazgo omitido.

Para **cada** hallazgo, en este formato:

```
### H-nn · <título de una línea>
**Fichero:línea** · **Severidad:** crítica | alta | media | baja | nit ·
**Confianza:** alta | media | baja · **Categoría:** optimalidad | corrección | invariante |
aritmética | tiempo/calendario | rendimiento | concurrencia | testabilidad | deuda

**Qué pasa.** El comportamiento observable, no la abstracción.
**Instancia mínima.** El timetable, la consulta o el contraejemplo concreto que lo expone,
en código ejecutable si cabe. Si no has podido construirlo, dilo.
**Por qué pasa.** La causa en el código, citando las líneas.
**Cómo lo arreglaría.** El cambio mínimo.
**Cómo lo verificaría.** El test concreto — nombre, fichero donde iría, y qué mutación del
código de producción debería tumbarlo.
```

Distingue con rigor tres cosas y no las mezcles nunca: **lo que has ejecutado y observado**, lo
que has **demostrado** sobre el código, y lo que **razonas** que ocurriría. Cuando afirmes que
el motor devuelve una respuesta subóptima, la instancia mínima es obligatoria: en este dominio
una sospecha sin contraejemplo no es un hallazgo, es una hipótesis, y debe ir etiquetada como
tal con confianza baja.

Estructura final del informe:

1. **Resumen ejecutivo** — 10 líneas como máximo: en qué estado está el motor y las tres cosas
   que arreglarías primero.
2. **Qué pudiste ejecutar** — feed real sí o no, cuántas instancias aleatorias, qué mutaciones,
   cuánto tardó. Es lo que permite calibrar todo lo demás.
3. **Tabla de hallazgos** — todos, ordenados por severidad y luego por fichero.
4. **Hallazgos en detalle** — con el formato de arriba.
5. **Resultados de la mutación** — tabla de mutación → tests que fallaron → veredicto sobre la
   cobertura de esa zona.
6. **Mapa del motor** — el recorrido real de una consulta desde `PlanQuery` hasta
   `visibleJourneys`, con cada estructura de datos, cada recorte y cada criterio aplicado, y
   dónde se toma cada decisión irreversible. Escríbelo aunque no encuentres nada mal: es la
   mitad del valor de esta auditoría.
7. **Lo que está bien** — decisiones que aguantan el escrutinio y que un refactor futuro no
   debería deshacer sin entenderlas. Sé específico; no es una sección de cortesía.
8. **Plan sugerido** — los hallazgos agrupados en tandas coherentes, cada una con lo que habría
   que verificar para darla por buena. Ordenadas por valor entregado, no por severidad.

Escribe el informe en **castellano**, en `AUDITORIA-RAPTOR.md`, en la raíz del repo. Es el
único fichero del repositorio que puedes crear.

## 7. Cómo empezar

1. Lee los cinco documentos del §1 antes de abrir código. La bitácora de la Fase 3 en
   `ESTADO.md` te dice dónde ya hubo bugs y de qué tipo, que es la mejor pista de dónde
   quedan más.
2. Ejecuta `swift test` en `VigoCore/` para partir de una suite verde y saber cuánto tarda.
3. Lee **todos** los ficheros del inventario del §2.1 antes de escribir un solo hallazgo. Un
   juicio sobre `RaptorEngine` sin haber leído `TimetableBuilder` será equivocado: la mitad de
   las precondiciones del motor las establece el constructor.
4. Monta la infraestructura de verificación del §5 **antes** de empezar a escribir hallazgos, y
   trabaja con ella en la mano. En este motor, leer código sin poder ejecutar contraejemplos
   produce una auditoría de opiniones.
5. Recorre los diez ejes del §4 fichero por fichero.
6. Escribe el informe.
