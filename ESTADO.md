# ESTADO.md — Estado de la implementación

Documento vivo. Se actualiza al terminar cada paso, no al final de la sesión. El plan
completo de cada fase vive en `ILoveVigoRoutes-HANDOFF.md`; esto es solo "dónde estamos".

---

## Resumen

| Fase | Estado |
|---|---|
| Fase 0 — Verificación y cimientos | ✅ Hecha |
| Fase 1 — Paradas y tiempo real | ✅ Hecha |
| Fase 2 — Ferry de la ría | ⬜ No empezada |
| **Fase 3 — Planificador de rutas (RAPTOR)** | ✅ Completa (solo bus) |
| Fase 4 — Pulido y comodidades | ⬜ No empezada |

---

## Fase 3 — Planificador de rutas

Plan detallado (arquitectura, ficheros, secuencia completa de 11 pasos) en
`~/.claude/plans/actua-como-un-planificador-immutable-parnas.md`. Resumen de decisiones:
solo bus (ferry fuera hasta que exista Fase 2), solo consultas hacia delante, tiempo real
fuera del motor, RAPTOR y no CSA, `Timetable` en memoria sin migración de esquema.

### Hecho

- [x] **1/11 — `PlannerOptions` + `WalkModel`** (`b4edb59`)
  `VigoCore/Sources/VigoCore/Planner/PlannerOptions.swift`,
  `VigoCore/Sources/VigoCore/Planner/WalkModel.swift`.
  9 parámetros de política documentados. Conversión metros→segundos redondeando siempre
  hacia arriba. `footpaths(stops:)` con barrido por latitud, contrastado por test contra
  escaneo cuadrático completo (200 paradas, semilla fija).

- [x] **Fix de deuda, no planeado** — `f4a1282`
  `GTFSImporter.import` tomaba `Date()` real en vez del reloj que el llamador ya usaba;
  dos tests de `FeedServiceTests` solo pasaban antes de las 09:00 (Madrid). Ahora
  `import(importedAt:)` recibe el reloj, y `GTFSFeedService` le pasa el mismo `now` que usa
  para la hora de comprobación. Sin esto no se podía seguir con paso 2 con la suite verde.

- [x] **2/11 — `Timetable` + `TimetableBuilder`** (`1639109`)
  `VigoCore/Sources/VigoCore/Planner/Timetable.swift`,
  `VigoCore/Sources/VigoCore/Planner/TimetableBuilder.swift`.
  Snapshot en memoria, arrays CSR en `Int32`, sin migración de esquema. Pliega tres días de
  servicio sobre un eje temporal único; el desplazamiento entre días es la diferencia real
  entre medianoches (no 86400 fijo, por el cambio de hora). Separa patrones que se
  adelantan. Contra el feed real: 188 patrones, 1892 viajes, 70679 tiempos, 0,6 MB,
  construido en 34 ms — dentro del presupuesto de <1s con margen amplio.
  Verificado por mutación: desactivar la separación por adelantamiento tumba 4/15 tests.

- [x] **3/11 — `RaptorEngine`** (`e017e57`)
  `VigoCore/Sources/VigoCore/Planner/RaptorEngine.swift`.
  Función pura `(Timetable, RaptorQuery) -> RaptorResult`. Rondas = frente de Pareto
  (llegada, transbordos). Embarca con la etiqueta de la ronda anterior, no la actual. Un
  solo salto a pie por ronda (sin punto fijo — la desigualdad triangular lo hace seguro).
  Poda por objetivo desde el inicio.
  **Aviso importante:** los 14 tests iniciales pasaron a la primera. Se probaron 4
  mutaciones deliberadas del motor; 2 pasaban desapercibidas porque la red sintética de
  pruebas no tenía la forma para exponerlas (embarcar con etiqueta de ronda en curso;
  encadenar caminatas). Se amplió la red (parada E, línea L6) hasta que las 4 mutaciones
  fallan. Ver commit `e017e57` para el detalle — es la evidencia de que "tests en verde"
  no bastaba por sí solo.

- [x] **4/11 — `BruteForceReference` + contraste aleatorizado**
  `VigoCore/Tests/VigoCoreTests/BruteForceReference.swift`,
  `VigoCore/Tests/VigoCoreTests/BruteForceReferenceTests.swift`.
  Referencia exhaustiva (sin búsqueda binaria, sin cola de posiciones, cada patrón
  reescaneado entero cada ronda) contra timetables sintéticos aleatorios construidos
  directamente sobre los arrays de `Timetable` (sin pasar por GTFS), 200 instancias con
  semilla fija (`SeededGenerator`, splitmix64).
  **Encontró un bug real en `RaptorEngine`, no solo en la referencia**: el paso 4 de
  relajación de footpaths (`RaptorEngine.swift`) leía `arrival[base + stop]` en vivo como
  origen de cada caminata. Si una parada `X` alcanzada en bici/bus en esta ronda recibía
  además una caminata entrante *antes* de que le tocara su turno como origen (`X` está en
  `riddenStops`, solo que más adelante en la lista), esa lectura recogía el valor ya
  corregido por la caminata entrante en vez del de la subida — encadenando dos caminatas en
  una ronda sin que ninguno de los dos bucles lo notara, justo lo que el diseño prohíbe
  explícitamente («un solo salto a pie por ronda») y lo que el test
  `oneWalkPerRound` no cazaba porque solo mira el `parent` final, no los valores
  intermedios usados para calcularlo. Arreglado tomando una foto (`rideArrival: [Int:
  Int32]`) de las llegadas en bus antes de que el bucle de caminatas escriba nada; la
  referencia tenía el mismo fallo y se corrigió igual. Sin el contraste aleatorizado este
  bug no tenía ningún test que lo detectara — los 14+4 tests de ejemplo del paso 3 pasaban
  igual de verdes con o sin él.

- [x] **5/11 — Reconstrucción de viajes + ajuste hacia atrás + selección de alternativas**
  `VigoCore/Sources/VigoCore/Planner/Place.swift`, `Journey.swift`, `JourneyReconstruction.swift`;
  tests en `VigoCore/Tests/VigoCoreTests/JourneyReconstructionTests.swift`.
  `Place` (parada, o coordenada con etiqueta — ubicación/mapa) y `Journey`/`JourneyLeg` tal
  como los describe el plan. `JourneyReconstruction.alternatives` recorre los `parent` de
  `RaptorResult` hacia atrás por ronda (un `.ride` retrocede a la ronda anterior en la
  parada de subida, un `.walk` se queda en la misma ronda), arma la cadena hacia delante y
  aplica la pasada de ajuste: desde la llegada fija del último tramo, cada tramo en autobús
  se recalcula al **viaje más tardío** del mismo patrón que sigue llegando a tiempo, y el
  límite se propaga hacia atrás restando `minTransferSeconds` (mismo andén),
  `footpathBufferSeconds` + segundos de la caminata (transbordo a pie), o nada (tramo de
  acceso, que fija la hora de salida real). Una ronda por candidata (ya es frente de
  Pareto por construcción: más transbordos solo aparece si mejora la llegada), filtrado por
  `extraTransferWorthSeconds` contra la última alternativa aceptada, orden por llegada,
  tope de 3.
  Verificado por mutación: anular la pasada de ajuste (usar siempre el viaje ya encontrado)
  tumba el test dedicado con una red construida a propósito (tres viajes de un mismo patrón
  cada 5 minutos hacia una única conexión fija) — sin esa red los ejemplos del paso 3/4 no
  tenían margen suficiente para exponerlo, exactamente el mismo patrón de riesgo que ya
  apareció en los pasos anteriores.
  **Desviación del plan:** el fichero de test se llama `JourneyReconstructionTests.swift`,
  no `JourneyPlannerTests.swift` — ese nombre lo tomará el paso 6, cuando exista de verdad
  la fachada `JourneyPlanner` que el plan describe para ese fichero.

- [x] **6/11 — `TimetableStore` + `JourneyPlanner` + todos los `PlanOutcome`**
  `VigoCore/Sources/VigoCore/Planner/TimetableStore.swift`, `JourneyPlanner.swift`;
  tests en `JourneyPlannerTests.swift` (facade), `TimetableStoreTests.swift`.
  `TimetableStore` es el segundo actor del paquete (junto a `ThrottledRealtimeProvider`),
  pero más simple: `TimetableBuilder.build` no tiene ningún punto de suspensión dentro, así
  que la propia serialización del actor ya basta para que dos peticiones concurrentes
  esperen a una sola construcción — no hace falta el `inFlight`/`Task` que sí necesita
  `ThrottledRealtimeProvider` (esa sí llama a una red asíncrona real). Caché LRU de 3
  entradas, clave (día ancla, `feedStatus.importedAt`).
  `JourneyPlanner.plan` sigue el orden literal del plan: resuelve accesos/salidas por
  `nearbyStops` con el radio de acceso, comprueba ventana del feed y día de servicio, pide
  el `Timetable` al store, corre `RaptorEngine`, reconstruye con `JourneyReconstruction`, y
  decide entre `.journeys`, `.walkOnly` y `.noJourneyFound` comparando la caminata directa
  contra la mejor alternativa en autobús.
  **Desviación del plan, justificada:** el plan no dice cuándo `.noJourneyFound` debe
  ganarle a `.walkOnly` — tal cual estaba escrito ("si caminar es más rápido... walkOnly"),
  caminar siempre "gana" cuando no hay autobús, y `.noJourneyFound` quedaría inalcanzable
  pese a ser un caso que el propio plan pide probar. Añadido un límite: la caminata directa
  solo es una alternativa válida si tarda `<= options.searchHorizon` (el mismo presupuesto
  que ya usa la búsqueda en autobús); si no, y no hay autobús, es `.noJourneyFound`.
  Verificado por mutación: anular el recorte por capacidad de `TimetableStore` tumba el
  test de desalojo con un mismatch de contenido, no solo un contador.
  El nombre `JourneyPlannerTests.swift` que el paso 5 dejó pendiente para "cuando exista de
  verdad la fachada" ya está en uso, tal como el plan lo preveía.

- [x] **7/11 — Integración con el feed real + asserción de <1s**
  `VigoCore/Tests/VigoCoreTests/RealFeedIntegrationTests.swift` (ampliado).
  Nuevo test `realJourneyPlan`: Praza de América → Urzaiz (~1,3 km, centro de Vigo) con
  `JourneyPlanner` contra el archivo real, aceptando `.journeys`, `.walkOnly` o
  `.noServiceOnDay` (un hueco real de calendario no es un defecto) y fallando para
  cualquier otro caso. `RealFeedTimingTests.importTimings` añade la única asserción dura de
  la fase: `planElapsed < 1.0` sobre una construcción de `Timetable` **en frío** (el caso
  peor: nunca se había construido para ese día) más `RaptorEngine` más reconstrucción —
  medido: **40 ms** contra el feed real (1154 paradas, 3801 viajes, 137456 stopTimes),
  25× de margen sobre el presupuesto de 1s del handoff.
  **Detalle no obvio:** la consulta usa el día del propio `feed.serviceWindow`, no "hoy" —
  el archivo descargado es una foto fija y su ventana de 7 días no siempre incluye la fecha
  real en la que corre el test (el archivo usado aquí, descargado el 2026-09-04, reporta
  ventana 20260905–20260911, es decir *empieza mañana*). Usar `Date()` directamente habría
  dado `.outsideFeedWindow` de forma intermitente según cuándo se ejecute la suite.

- [x] **8/11 — App: cirugía de `RootView`, "Fuentes" a Favoritas, `AppEnvironment`**
  `App/ILoveVigoRoutes/Views/RootView.swift`, `Views/FavouritesView.swift`,
  `AppEnvironment.swift`, `Info.plist`.
  `AppTab` gana `.planner` (quinta posición ocupada, así que `.sources` desaparece);
  pestaña "Planificar" (`arrow.triangle.turn.up.right.diamond`) en 3ª posición, entre
  "Cercanas" y "Buscar". "Fuentes" pasa a un botón de información en la barra de
  navegación de `FavouritesView`, a nivel del `NavigationStack` (no dentro de
  `content(_:)`), para que exista también con cero favoritas; abre `DataSourcesView` en
  una hoja en vez de empujarla en la propia `NavigationStack` de Favoritas.
  `AppEnvironment` gana `let planner: JourneyPlanner` y un `TimetableStore` propio,
  precalentado en `init` con `Task.detached(priority: .utility)` para el día de hoy — el
  mismo patrón que ya usa `refreshFeed`. `Info.plist` amplía la descripción de ubicación
  para mencionar la planificación.
  **Desviación del plan, señalada por necesidad, no por elección:** el plan reserva
  `PlannerView.swift` para el paso 9, así que la pestaña "Planificar" de este paso apunta a
  un `PlannerPlaceholderView` provisional en el propio `RootView.swift` — se sustituye por
  la vista real en el paso 9.
  Verificado en el simulador (iPhone 17 Pro): las 5 pestañas se ven correctas
  (Favoritas/Cercanas/Planificar/Buscar/Mapa, sin "Fuentes"), el botón de información abre
  la hoja de "Fuentes de datos" con el `feedStatus` real, y la pestaña "Planificar" muestra
  el placeholder. De paso, confirma en vivo lo que el paso 7 ya había medido: la ventana del
  feed real descargado hoy es 05/09–11/09, es decir, no cubre "hoy" (04/09).

- [x] **9/11 — `PlannerView` + `PlacePickerView`**
  `App/ILoveVigoRoutes/Views/PlannerView.swift`, `PlacePickerView.swift`,
  `MapPointPickerView.swift`, `JourneyRows.swift`.
  `PlannerModel` sigue el patrón de `StopDetailModel`: origen/destino como `Place?`,
  intercambio, modo de salida (ahora / a una hora), y `plan()` llamando a
  `environment.planner.plan(_:)`. `PlacePickerView` cubre las cuatro formas de elegir sitio
  que pide el handoff — mi ubicación, favorita, resultado de `searchStops` (sin debounce,
  igual que `SearchView`), y "elegir en el mapa" vía `MapPointPickerView` (mismo patrón de
  `Map`/`MapCameraPosition` que ya usa `StopsMapView`, pin fijo en el centro en vez de
  anotación arrastrable). `JourneyRows.swift` trae `JourneyAlternativeRow` (resumen: hora,
  hora, duración, chips por tramo) y `JourneyLegRow` (tramo expandido, para cuando exista
  `JourneyDetailView` en el paso 10), reutilizando `LineBadge`/`WaitTime` de
  `DataProvenanceViews.swift`.
  Verificado en el simulador (iPhone 17 Pro) contra el feed real completo: Praza de
  América → Rúa de Urzáiz un día dentro de la ventana (05/09) encuentra la ruta real
  (línea 29, directo, 14 min, con los tramos a pie de entrada y salida correctos); el mismo
  origen/destino "ahora" (04/09, fuera de ventana) devuelve el mensaje de
  `outsideFeedWindow` correcto. Confirma en el simulador, con interacción real, lo que los
  pasos 6 y 7 ya habían probado por código.
- [x] **10/11 — `JourneyDetailView` con trazado real desde `shapePoint`**
  `App/ILoveVigoRoutes/Views/JourneyDetailView.swift`;
  `VigoCore/Sources/VigoCore/Persistence/TransitRepository.swift` gana `trip(id:)`.
  Primer uso real de `shapePoint`/`TransitRepository.shape(id:)`, importados e indexados
  desde la Fase 0 pero sin ningún lector hasta ahora. Cada tramo en autobús resuelve
  `tripID → Trip → shapeID → [ShapePoint]` y recorta el trazado entero de la línea a la
  parte realmente recorrida: el helper que pedía el plan, por punto más cercano (no por
  índice de secuencia, porque GTFS no promete un `shapePoint` exacto en cada parada, solo
  que la parada cae cerca del trazado). `Map` con `MapPolyline` + marcadores de
  origen/subida/bajada/destino, y debajo la lista de tramos con `JourneyLegRow` (ya escrito
  en el paso 9). `PlannerView` engancha cada alternativa con un `NavigationLink`.
  Verificado en el simulador contra el feed real: el tramo en autobús (línea 23,
  Avda. de Castrelos → Rúa de Pizarro) dibuja el trazado real siguiendo las calles, no una
  línea recta entre las dos paradas.
  Añadido de paso: `RepositoryTests.tripLookup` cubre el `trip(id:)` nuevo (encuentra el
  `shapeID`, y `nil` para un id inexistente).
- [x] **11/11 — Anotación con tiempo real del primer embarque + `README.md`**
  `App/ILoveVigoRoutes/Views/JourneyDetailView.swift`; `README.md` (tabla de estado).
  `JourneyDetailView` cruza el primer tramo en autobús con `environment.arrivals` (la
  misma `ArrivalsService` que ya usa el resto de la app): mismo `normalizedLine`, y de entre
  las llegadas de esa línea en la parada de subida, la que tiene una hora implícita
  (`ahora + minutos`) más cercana a la hora de salida ya fijada por la reconstrucción —
  aceptada solo dentro de 15 minutos de margen, para no confundir el autobús que se busca
  con el siguiente de la misma línea. Fuera del motor por diseño (la decisión de Fase 3 lo
  dice explícitamente): el tiempo real solo anota, nunca decide la ruta. Con una consulta a
  fecha futura (no "ahora") no hay nunca coincidencia, que es lo correcto — el tiempo real
  no puede saber nada de un autobús que aún no está por llegar.
  `README.md`: Fase 1 pasa de "Pendiente" a "Completa" (ya lo estaba, era una tabla
  desactualizada) y Fase 3 pasa de "No iniciada" a "Completa (solo bus; el ferry entra
  cuando exista la Fase 2)".
  Verificado en el simulador contra el feed real: sin coincidencia para una consulta a
  futuro (05/09 con "hoy" en 04/09) no aparece ningún aviso, y no hay ningún fallo — el
  camino más frecuente en la práctica, ya que el feed real de esta sesión no cubre "ahora".

**Fase 3 completa — 11/11 pasos.** Motor RAPTOR contrastado por fuerza bruta, reconstrucción
con ajuste hacia atrás, planificador cacheado con presupuesto de <1s medido en 40 ms contra
el feed real, y las cuatro pantallas de la app (pestaña, selector de sitio, detalle con
trazado real, anotación de tiempo real) verificadas a mano en el simulador. Commits
`fa01bd8`..`HEAD` en `main`. Próximo trabajo de fondo: Fase 2 (ferry) o Fase 4 (pulido) —
ver `ILoveVigoRoutes-HANDOFF.md` para su alcance, que este documento no cubre.

### Cambio posterior — geocodificación de direcciones

- [x] El selector de origen/destino acepta ahora direcciones y puntos de interés mediante
  Apple Mapas, siempre acotados a una región fija de Vigo. `MapKitAddressSearchService` queda
  aislado detrás de `AddressSearching`; `AddressSearchModel` hace debounce de 300 ms y las
  pruebas del target de app verifican el contrato con un stub, sin tocar `VigoCore`.
- [x] La interfaz distingue las direcciones de las paradas, explica qué texto se envía a Apple
  y nunca envía la ubicación del usuario. Una coordenada de `placemark` puede ser el centroide
  de una calle y no el portal exacto, así que el tramo a pie hacia una dirección es menos fino
  que el que termina en una parada.

### Cambio posterior — origen automático, 4 alternativas y mapa de navegación

- [x] **Origen por defecto = tu ubicación.** `PlacePickerView` devuelve ahora un `PickedPlace`
  (el lugar y si vino del GPS), porque `Place` no puede distinguir "Mi ubicación" de una
  dirección resuelta: las dos son `.coordinate`. `PlannerModel` guarda esa distinción en
  `originFollowsLocation`: mientras sea cierto, cada nuevo fix actualiza el origen; elegir un
  sitio a mano o intercambiar origen y destino lo apaga, y el botón "Usar mi ubicación" lo
  vuelve a encender. `PlannerModel` pasa a recibir el `JourneyPlanner` en vez del
  `AppEnvironment` entero, lo que lo hace comprobable sin CoreLocation ni base de datos en
  disco (`App/ILoveVigoRoutesTests/PlannerModelTests.swift`, 6 tests).
- [x] **4 alternativas, con salidas posteriores.** Una sola ejecución de RAPTOR solo varía los
  transbordos: todas sus opciones salen a la misma hora, y con el filtro de
  `extraTransferWorthSeconds` el resultado real era casi siempre 1. `JourneyPlanner` hace ahora
  un escaneo tipo rRAPTOR: tras cada pasada reinicia la búsqueda un segundo después del primer
  embarque encontrado, lo que obliga a la siguiente a coger un vehículo posterior. Cota doble
  (`maxDepartureScans`, y el horizonte de búsqueda como fecha límite) para que el bucle termine
  siempre. El conjunto se deduplica, se filtran los trayectos dominados (salir antes, llegar
  después y con más transbordos no es alternativa de nadie) y se ordena por llegada, con tope
  `maxAlternatives` (4). El `.prefix(3)` incrustado en `JourneyReconstruction` pasa a ser esa
  misma opción.
  Contra el feed real (Praza de América → Urzaiz, 09:00): **4 alternativas** con líneas
  distintas — 17 (9:02→9:15), 11 (9:07→9:21), 10 (9:11→9:31) y C1 (9:15→9:33), todas directas.
  Coste: 129 ms en frío (construcción del `Timetable` incluida) y **21,6 ms en caliente**, con
  el presupuesto en 1 s.
- [x] **Del minimapa al mapa de navegación.** `JourneyTraceBuilder` y `JourneyMapContent`
  (`App/ILoveVigoRoutes/Views/JourneyTrace.swift`) sacan de `JourneyDetailView` la
  construcción del trazado, el recorte por punto más cercano y los marcadores, para que las dos
  pantallas dibujen exactamente el mismo trayecto. De paso, el encuadre deja de ser "el primer
  punto con span fijo" y pasa a ser el rectángulo mínimo que contiene todo el trayecto: antes
  los recorridos largos se salían de la vista.
  El minimapa del detalle es ahora una vista previa no interactiva (`allowsHitTesting(false)`,
  sin lo cual el `Map` se come el toque y el `NavigationLink` nunca dispara) que empuja
  `JourneyMapView`: mapa a pantalla completa, `UserAnnotation`, cámara `.userLocation`
  siguiendo con rumbo, botones "Seguirme" (visible en cuanto se mueve el mapa a mano) y "Ver
  todo el trayecto". Mientras está abierto se desactiva el autobloqueo y `LocationProvider`
  pide precisión `Best`, que restaura al salir; sigue siendo permiso `WhenInUse` y solo primer
  plano, sin cambios en `Info.plist`. Sin lógica de progreso ni avisos de bajada: decisión
  explícita, porque todo eso son promesas sobre el vehículo que el horario solo no puede
  cumplir.

## Verificación rápida del estado

```bash
cd VigoCore && swift test 2>&1 | tail -3
xcodebuild -scheme ILoveVigoRoutes -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
git log --oneline -5
```
Al escribir este documento: **170 tests de `VigoCore` en verde** (164 antes de este cambio;
+5 en `JourneyAlternativesTests`, +1 en `JourneyReconstructionTests`), incluida la suite del
feed real con `VIGO_GTFS_ZIP` apuntando al archivo publicado, y **12 tests del target de app**
(`AddressSearchModelTests` + `PlannerModelTests`). Falta la comprobación a mano en dispositivo
del seguimiento en movimiento, que no se puede hacer desde aquí.
