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
| Fase 4 — Pulido y comodidades | 🟡 Parcial: lugares/trayectos guardados, refresco en segundo plano, orden de pestañas, estrella unificada. Sin widget, atajos de Siri ni accesibilidad |
| **Fase 5 — El mapa como planificador** | ✅ Completa y comprobada en dispositivo |
| **Fase 6 — Retirada de lo viejo** | ✅ Hecha. Pendiente de comprobación en dispositivo |
| **Fase 7 — Un solo buscador, dos pestañas** | ✅ Hecha y fusionada a `main` |
| **Fase 8 — Caminatas en el mapa y actualizar a mano** | ✅ Hecha y comprobada en dispositivo |
| **Fase 9 — Horarios de una línea en una parada** | ✅ Hecha y comprobada en dispositivo |
| **Fase 10 — Criterio de ordenación de alternativas** | ✅ Hecha y comprobada en dispositivo |
| **Fase 11 — Trayecto activo persistente** | ✅ Hecha. Pendiente de comprobación en dispositivo |
| **Auditoría del buscador** | 🟡 Tanda A hecha (correcciones de emparejamiento). B–D en `AUDITORIA-BUSCADOR.md` |

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

## Fase 4 — Lugares/trayectos guardados y refresco en segundo plano

Plan detallado en `~/.claude/plans/humble-hopping-backus.md`. Alcance: lo que pedía el
propietario (CRUD completo de lugares y trayectos guardados, orden de pestañas, estrella de
favorito unificada, refresco del GTFS en segundo plano), descartando explícitamente el widget
de WidgetKit — y con él el App Group y la reubicación de la base de datos — por complejidad
desproporcionada para lo que aporta ahora mismo.

### Hecho

- [x] **Reordenar pestañas.** `App/ILoveVigoRoutes/Views/RootView.swift`: Mapa → Planificar →
  Favoritas → Buscar → Cercanas. La pestaña de arranque sigue siendo Favoritas
  (`selection = .favourites`) — el orden de declaración de las `Tab` no decide cuál se
  selecciona al arrancar, solo el orden visual.

- [x] **`FavouritesStore`: una sola fuente de verdad para el estado de favorito.**
  `App/ILoveVigoRoutes/FavouritesStore.swift` (nuevo), propiedad de `AppEnvironment`.
  Arregla el bug real que motivó este paso: `StopDetailModel.isFavourite` se fotografiaba en
  el `init` y `FavouritesModel` guardaba su propia copia de `[Stop]`, así que marcar una
  parada en una pantalla dejaba la estrella de otra pantalla equivocada hasta que recargara
  por su cuenta. `TransitRepository` gana `favouriteStopRows()` (todas las filas, incluida la
  de una parada que el feed vigente ya no tiene) para poder decirlo en voz alta
  (`unresolvedIDs`) en vez de descartarla en silencio. `AppEnvironment.refreshFeed` recarga el
  store tras cada reimportación.
  Test de regresión: `App/ILoveVigoRoutesTests/FavouritesStoreTests.swift` — un store, dos
  lectores, mutar por un camino y comprobar que el otro lo ve.

- [x] **Estrella de favorito en todas las pantallas.**
  `App/ILoveVigoRoutes/Views/FavouriteAffordance.swift` (nuevo): `FavouriteStarButton`
  (barra), swipe (borde izquierdo) + menú contextual reutilizables vía
  `.favouriteActions(for:)`. Aplicado a `NearbyView`, `SearchView` y a las filas de parada de
  `PlacePickerView`. `StopsMapView` no necesitó nada nuevo: su hoja de selección ya empuja
  `StopDetailView`, cuya estrella pasa a leer del store. `JourneyDetailView`/`JourneyRows.swift`
  usa solo menú contextual (dos entradas explícitas, una por parada) porque una fila `.ride`
  muestra origen y destino a la vez — un swipe ahí sería ambiguo sobre cuál de los dos.

- [x] **VigoCore: persistencia de lugares y trayectos guardados.**
  `VigoCore/Sources/VigoCore/Persistence/SavedPlaceRecords.swift` (nuevo): `SavedPlace`,
  `SavedJourney`, `SavedPlaceAnchor` (`.stop` / `.orphanedStop` / `.coordinate`),
  `SavedEndpoint` (enlace vivo a un lugar guardado, con una instantánea congelada para cuando
  el enlace desaparece). Migración `"v2"` en `AppDatabase.swift` (tablas `savedPlace` y
  `savedJourney`, sin FK a `stop` — el importador la borra y reescribe entera cada semana).
  CRUD completo en `TransitRepository.swift`. Regla que gobierna todo el diseño: nunca se
  persiste un `Stop`; un lugar anclado a parada guarda `stopID` + coordenada de respaldo y se
  resuelve contra la tabla `stop` viva en cada lectura, degradando a `.orphanedStop` (todavía
  planificable) si el feed ya no la tiene.
  Verificado por tests: `SavedPlacesTests.swift` (19 tests — CRUD completo, plantillas no son
  huecos únicos, resolución contra el `Stop` vivo tras reimportar, orfandad, propagación de
  renombrados a un trayecto, `customLabel` frente a derivado, extremos ad-hoc nunca
  enlazados), `MigrationTests.swift` (datos de `v1` sobreviven a `v2`), y ampliación de
  `RepositoryTests.swift` (lugares/trayectos sobreviven a una reimportación; una favorita cuya
  parada desapareció se queda en las filas crudas pero no en la lista resuelta).

- [x] **UI de lugares y trayectos guardados.**
  `App/ILoveVigoRoutes/SavedPlacesStore.swift` (nuevo, hermano de `FavouritesStore`),
  `Views/SavedPlaceEditorView.swift` y `Views/SavedJourneyEditorView.swift` (nuevos, crear y
  editar comparten formulario). Plantillas (Casa/Trabajo/Hospital/Centro de salud/Gimnasio/
  Otro) solo prerrellenan nombre e icono al crear — no hay columna de plantilla ni singleton,
  dos lugares de la misma plantilla conviven con nombres propios.
  `FavouritesView.swift` reescrita con tres secciones (Trayectos guardados, Lugares, Paradas
  favoritas), cada una con `.onDelete`/`.onMove`/menú contextual (Editar/Duplicar/Eliminar) y
  un menú "+" para crear. Tocar un trayecto lo planifica al instante
  (`SavedJourneyPlanModel` + `.navigationDestination(item:)` hacia la mejor alternativa).
  `PlacePickerView` gana secciones "Lugares guardados" y "Trayectos guardados" (esta última
  solo cuando se le pasa un `role: .origin`/`.destination`, para elegir el extremo correcto y
  no recursar al elegir el extremo de un trayecto nuevo), más un swipe "Guardar" en filas de
  parada y de dirección resuelta (`SavedPlaceEditorView(mode: .createFrom(place))`).
  **Bug encontrado y corregido durante la verificación en el simulador:** el aviso de
  extremo "ya no existe" se disparaba también para un extremo elegido ad-hoc a propósito
  (`Elegir otro lugar`), que es `isDetached == true` por diseño, no por borrado — un aviso
  falso. Corregido para avisar solo cuando el ancla de un extremo está realmente huérfana
  (`anchor.isOrphaned`, parada que el feed ya no tiene), la única señal que de verdad se puede
  verificar.
  Verificado en el simulador (iPhone 17 Pro) contra el feed real: crear un lugar desde
  plantilla, elegir punto en el mapa, guardar; crear un trayecto con un extremo enlazado y
  otro ad-hoc; tocarlo planifica y empuja `JourneyDetailView` con el tramo real; marcar
  favorita una parada desde "Buscar" aparece de inmediato en "Favoritas" sin recargar —
  confirma en vivo el arreglo del bug de estrella desincronizada.
  Tests: `App/ILoveVigoRoutesTests/SavedPlacesStoreTests.swift` (plantillas no son
  singleton, ciclo CRUD completo, `reload()` recoge mutaciones externas), ampliación de
  `PlannerModelTests.swift` (fijar origen desde un lugar guardado usa su nombre y apaga el
  seguimiento del GPS).

- [x] **Refresco del GTFS en segundo plano.**
  `App/ILoveVigoRoutes/BackgroundRefresh.swift` + `AppDelegate.swift` (nuevos).
  `BGProcessingTask`, no `BGAppRefreshTask`: la importación descarga ~16 MB, descomprime,
  parsea y escribe ~280k filas en una sola transacción — muy por encima de lo que una ventana
  de app-refresh puede terminar. `AppDelegate` pasa a ser el único dueño de `AppEnvironment`
  (antes vivía en `@State` de `ILoveVigoRoutesApp`) porque el registro de la tarea tiene que
  ocurrir antes de que `didFinishLaunchingWithOptions` termine, y ese es el único punto del
  ciclo de vida donde eso está garantizado. `handle` llama a `environment.refreshFeed()` sin
  `force` — `GTFSFeedService.shouldCheck` ya tiene la política correcta para una ejecución
  oportunista — y reprograma siempre al terminar. El `refreshFeed()` de arranque en frío se
  mantiene como red de seguridad: iOS puede no llegar a ejecutar nunca la tarea de fondo.
  Cubre solo el feed GTFS; los endpoints de tiempo real siguen sin sondearse nunca en segundo
  plano, por diseño.
  Verificado en el simulador vía `log show`: `BGTaskScheduler` registra y envía
  `BGProcessingTaskRequest` con el identificador, `requiresNetworkConnectivity=1` y
  `requiresExternalPower=0` correctos — un identificador no declarado en
  `BGTaskSchedulerPermittedIdentifiers` habría hecho crashear la app al registrar, y no
  crasheó.

**Fase 4, parcial.** CRUD de lugares y trayectos guardados, estrella de favorito unificada,
orden de pestañas y refresco en segundo plano — hechos y verificados. Widget de WidgetKit,
atajos de Siri y accesibilidad exhaustiva quedan fuera por decisión del propietario.

## Fase 5 — El mapa como planificador

Plan detallado en `~/.claude/plans/quiero-que-me-ayudes-mapful-astrolabe.md`. Alcance: el mapa
pasa a ser la pantalla del producto — seleccionar cualquier sitio (parada, POI de Apple,
dirección, punto suelto) y planificar sin salir de ahí, con hoja por detentes; y las paradas
dejan de dibujarse por defecto, pasando a ser una capa conmutable. La pestaña "Planificar"
sigue viva a propósito hasta que el mapa cubra la lista de paridad de 11 puntos del plan.

### Hecho

- [x] **0/11 — Sonda de MapKit en dispositivo real** (`5c5ce4c`, revertida en el commit
  siguiente).
  `App/ILoveVigoRoutes/Views/Map/MapSpikeView.swift` + un botón solo en DEBUG en la barra del
  mapa. Código desechable por diseño: existe únicamente para contestar en un iPhone las cuatro
  preguntas que la interfaz del SDK no puede responder, y se borra al cerrar el paso. Queda en
  el historial por si hiciera falta rescatarla.
  **Sin simulador en ningún momento** — decisión del propietario: compilación contra
  `generic/platform=iOS` con `CODE_SIGNING_ALLOWED=NO` como único oráculo local, y la conducta
  verificada a mano en un iPhone con iOS 26.6.1.

  **Contestado por compilación** (Debug y Release, sin avisos):
  `Map(position:selection:)` con `Binding<MapSelection<StopID>?>` compila, y la etiqueta
  correcta del marcador es `.tag(MapSelection(stop.id))`, no `.tag(stop.id)`.
  `.mapFeatureSelectionAccessory(_:)` acepta un ternario a `nil`. `MapProxy.convert(_:from:)`
  dentro de `MapReader` da la coordenada de un punto de pantalla. Release compila **sin** la
  sonda, así que el `#if DEBUG` no deja referencias colgando.

  **Contestado en el iPhone:**
  - **P1 — selección mixta: SÍ.** La misma binding devuelve `.value` al tocar un `Marker`
    propio (paradas 3067 y 3027) y `.feature` al tocar un POI de Apple (Castelo do Castro,
    `MKPOICategoryCastle`; El Corte Inglés, `MKPOICategoryStore`). Esto es lo que sostiene la
    exigencia nº 1 del propietario, y era el riesgo R1 del plan: **cerrado**.
  - **P2 — `mapFeatureSelectionAccessory(nil)` apaga la tarjeta nativa: SÍ.** Los dos POIs se
    seleccionaron con el conmutador en OFF sin que Apple pintara su propia tarjeta.
  - **P3 — pulsación larga: SÍ, la receta A funciona.** `simultaneousGesture` de
    `DragGesture(minimumDistance: 0)` (que solo anota la posición del dedo) más
    `LongPressGesture(minimumDuration: 0.45)` da coordenadas correctas sin robarle el paneo al
    mapa. La receta B (retícula central) se probó como control y también funciona, pero **no
    hace falta**: el plan B queda descartado.
  - **P4 — mapa manipulable con la hoja arriba: SÍ.**

  **Dos hallazgos que NO coinciden con lo que el paso esperaba.** Se anotan porque los dos
  cambian código futuro:

  1. **Deseleccionar no pone la binding a `nil`.** Tras seleccionar El Corte Inglés y tocar
     mapa vacío, saltó la rama que la sonda llevaba puesta como detector de anomalías:
     *selección no vacía pero sin `.value` ni `.feature`*. La explicación está en la propia
     interfaz del SDK: `MapSelection` tiene `init(_ feature: MapFeature?)`, que **acepta
     `nil`**, así que al deseleccionar MapKit escribe un `MapSelection` vacío en vez de un
     `nil`. Consecuencia directa para el paso 4: tratar `selection != nil` como "hay algo
     seleccionado" dejaría la hoja abierta para siempre después de deseleccionar. La condición
     correcta es `selection?.value != nil || selection?.feature != nil`. Sin la sonda, este
     bug se habría descubierto con la hoja ya escrita.
  2. **El mapa seguía manipulable en el detente `.large`**, con
     `presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))`, que debería
     haberlo bloqueado a partir de medio. La pregunta que de verdad importaba —¿se puede
     mover el mapa con la hoja en el detente pequeño?— no se anotó por separado, pero queda
     contestada por implicación: `upThrough` es monótono, así que si la interacción está viva
     por encima del umbral, lo está también por debajo. El diseño no cambia y el efecto es
     benigno (en `.large` la hoja tapa casi todo el mapa de todas formas), pero el modificador
     **no se puede usar como si bloqueara nada**: si algún día hace falta bloquear de verdad,
     habrá que medirlo otra vez en iOS 26.

  **Detalle menor para el paso 4:** `MapFeature.pointOfInterestCategory` devuelve el valor
  crudo (`MKPOICategoryStore`). Como subtítulo hay que traducirlo, no pintarlo tal cual.

  La sonda y su botón de DEBUG se eliminan en el commit que cierra este paso.

- [x] **1/11 — `MapPlace` + `MapNavigationState`, en `VigoCore`**
  `VigoCore/Sources/VigoCore/MapFlow/MapPlace.swift`, `MapNavigationState.swift`;
  tests en `VigoCore/Tests/VigoCoreTests/MapNavigationStateTests.swift` (17 tests).

  **Desviación del plan, por la restricción de "sin simulador".** El plan situaba
  `MapScreenModel` entero en el target de app. Los tests del target de app necesitan un
  simulador para correr, así que aquí no habría podido verificar nada yo. El tipo se parte en
  dos por esa línea:
  - `MapNavigationState` — **`struct` en `VigoCore`**, con todas las transiciones como
    métodos `mutating` puros. Es el 100% de la lógica del flujo, y lo cubre `swift test` en
    el Mac sin simulador ni dispositivo.
  - `MapScreenModel` — el `@Observable @MainActor` del target de app, que poseerá uno de
    estos y añadirá solo lo que de verdad necesita un dispositivo: la llamada al planificador,
    el geocodificador, `@AppStorage` y CoreLocation. Se escribe en el paso 3, con la vista.

  No es un contorsionismo para poder probar: la partición cae donde ya estaba la costura. Lo
  que queda en la app es exactamente lo que no es una función pura del estado.

  `MapPlace` es `Place` más procedencia (`.stop` / `.pointOfInterest` / `.address` /
  `.savedPlace` / `.droppedPin` / `.currentLocation`), porque `Place` aplana en
  `.coordinate(_, label:)` todo lo que no es parada y la ficha del mapa necesita saber si hay
  una `Stop` detrás (llegadas en vivo, estrella de favorito), qué escribir de subtítulo y qué
  glifo dibujar. La Fase 3 ya había tenido que recuperar **un** bit de eso con `PickedPlace`;
  aquí hacen falta más. `Origin.pointOfInterest` no lleva `MKPointOfInterestCategory`: MapKit
  no entra en este paquete, y su valor crudo (`MKPOICategoryStore`) no es texto para enseñar
  a nadie — la app lo traduce antes de construir el `MapPlace`. Es el hallazgo menor del
  paso 0, ya cerrado.

  `MapNavigationState` fija la regla que sostiene la pantalla: **las vistas no deciden
  transiciones**. Un gesto se traduce en una llamada, y la vista dibuja lo que dice `mode`.
  Lo que hay dentro, con su razón:
  - `dismiss()` es **una sola tabla**: `.journeyDetail → .routing → ficha del destino →
    mapa limpio`, con `.browsing` como suelo. Repartida entre los gestos de la hoja (arrastrar,
    X, tocar fuera) dejaría de ser predecible, que es justo lo que se nota al usarla.
  - `clearSelection()` existe por el **hallazgo nº 1 del paso 0**: deseleccionar deja un
    `MapSelection` no nulo y vacío, así que la vista no puede usar "binding != nil" como
    "hay selección". Y solo cierra la ficha: deseleccionar un pin no cancela una ruta.
  - `invalidateResult()` tira el resultado en cuanto cambia la pregunta. Sin él, el mapa
    seguiría pintando el trazado anterior bajo unos extremos recién editados, y un detalle
    abierto sería el de una ruta que ya nadie pidió.
  - `planningFinished(.journeys([]))` **no** es un éxito vacío: se pliega a fallo. Una lista
    vacía en pantalla diría "hay opciones y no caben" cuando lo cierto es que no hay ninguna.
  - `originFollowsLocation` repite el contrato que la Fase 3 fijó para `PlannerModel`, y
    `swapEnds()` lo apaga: sin eso, el siguiente fix del GPS deshace el intercambio en
    silencio.
  - `routeQuery(now:)` recibe el reloj en vez de leerlo, por la misma razón que el paso de
    deuda de la Fase 3 (`f4a1282`) tuvo que arreglar en `GTFSImporter`: un test que depende
    de la hora real solo pasa a ciertas horas.

  **Verificado por mutación, seis veces** — los 17 tests pasaron a la primera, que es
  exactamente la señal que el paso 3/11 de la Fase 3 dejó escrita como sospechosa. Cada una de
  estas mutaciones tumba al menos un test: (1) `swapEnds` sin apagar el seguimiento del GPS;
  (2) `invalidateResult` sin salir del detalle; (3) `clearSelection` sin el guard de modo;
  (4) lista vacía tratada como éxito; (5) `dismiss` saltando del detalle al mapa limpio;
  (6) `selectAlternative` sin comprobar el índice.

  Suite de `VigoCore`: **211 tests en verde** (194 antes de la Fase 5, +17). Target de app sin
  cambios; Debug y Release compilan contra `generic/platform=iOS`.

- [x] **2/11 — `PlanOutcomeMessage`: una sola traducción de los ocho casos**
  `VigoCore/Sources/VigoCore/Planner/PlanOutcomeMessage.swift` (nuevo),
  `Model/ServiceTime.swift` (gana `ServiceDate.humanReadable`);
  `App/ILoveVigoRoutes/Views/PlannerView.swift` y `FavouritesView.swift` pasan a usarlo,
  `DataProvenanceViews.swift` pierde su copia de `humanReadable`.
  Tests: `PlanOutcomeMessageTests.swift` (10).

  Hecho **antes** de la UI del mapa a propósito: es refactor puro sobre código ya verificado,
  y hacerlo después habría significado escribir la tercera copia para luego borrarla.

  **No era solo duplicación: las dos copias ya habían divergido, y la peor perdía datos.**
  `SavedJourneyPlanModel` decía *"los horarios importados no cubren esta fecha"* **sin las
  fechas**, y *"no hay ninguna parada cerca del origen guardado"* **sin el radio**. Con un
  feed que solo cubre siete días, las fechas de cobertura son lo único con lo que el usuario
  puede hacer algo; el radio, igual. Unificar arregla esa regresión de camino, y hay un test
  dedicado a cada una de las dos para que no vuelva.

  Detalles con su razón:
  - `failure(_:context:)` devuelve **`nil`** para `.journeys` y `.walkOnly`. Es parte del
    contrato, no un descuido: son respuestas, no fallos, y quien pintara ese texto sin
    comprobarlo estaría disculpándose por una búsqueda que salió bien.
  - `context` solo cambia dos mensajes (`origen`/`origen guardado`), porque en un trayecto
    guardado el arreglo es editar el trayecto, no la consulta de ahora. Descartada la idea de
    que el contexto matizara también `outsideFeedWindow`: las fechas sirven igual en los tres
    sitios y la maquinaria extra no pagaba.
  - Horizonte de **cero segundos** → "ahora mismo", nunca "en las próximas 0 horas". No es
    hipotético: `MapNavigationState.planningFinished` pliega una lista vacía de alternativas
    a `noJourneyFound(horizon: 0)`, así que los pasos 1 y 2 se tocan justo ahí. Hay un test
    que los cruza, además del que prueba cada uno por su lado.
  - `ServiceDate.humanReadable` sube a `VigoCore` porque este mensaje lo necesita. Elimina el
    duplicado que vivía en la app; los cuatro usos que ya existían siguen igual.

  Vive en `VigoCore/Planner/`, junto al tipo que describe, y no en el target de app: es una
  función pura de un `PlanOutcome`, así que `swift test` la cubre en el Mac sin simulador.

  **Verificado por mutación, seis veces:** (1) un éxito devolviendo texto de fallo;
  (2) `outsideFeedWindow` sin las fechas; (3) sin el caso de horizonte cero; (4) el contexto
  ignorado; (5) el radio fuera del mensaje; (6) `humanReadable` sin relleno de ceros. Las seis
  tumban tests.

  Suite de `VigoCore`: **221 tests en verde** (+10). El target de app compila en Debug y
  Release contra `generic/platform=iOS`.

- [x] **3/11 — `MapScreen`: el mapa arranca limpio y las paradas son una capa**
  `VigoCore/Sources/VigoCore/MapFlow/MapStopsLayer.swift` (nuevo),
  `App/ILoveVigoRoutes/Views/Map/MapScreen.swift` y `MapScreenModel.swift` (nuevos),
  `RootView.swift` apunta ahí; **`Views/StopsMapView.swift` eliminada**.
  Tests: `MapStopsLayerTests.swift` (8).

  Cumple la segunda exigencia del propietario: *"no quiero que muestres directamente todas
  las paradas... por defecto quiero que no se vean, el mapa limpio"*. La preferencia vive en
  `UserDefaults` bajo `map.stopsVisible`, y no hace falta sembrarla: `UserDefaults.bool`
  devuelve `false` para una clave que nunca se escribió, que es justo el valor por defecto
  que se quiere.

  **Desviación del plan, deliberada.** El plan metía aquí la cápsula de búsqueda flotante y
  dejaba borrar `StopsMapView` para el paso 4. Se ha hecho al revés: la cápsula se va al
  paso 5, con la hoja de búsqueda que le da sentido —una barra que no hace nada es peor que
  ninguna barra—, y `StopsMapView` se borra ya, porque `MapScreen` alcanza su paridad
  completa en este mismo paso (selección de parada incluida, que sigue abriendo
  `StopDetailView` en una hoja). Así no conviven dos mapas divergiendo entre commits.

  **Lo que este paso NO hace todavía, a propósito:** no toca
  `mapFeatureSelectionAccessory`. Apagar la tarjeta nativa de Apple antes de tener una ficha
  propia que poner en su lugar dejaría el mapa peor durante un commit — tocar un POI no haría
  absolutamente nada. Entra en el paso 4, junto con la ficha.

  **`MapStopsLayer` sale de la vista y arregla una ambigüedad real de camino.** El método
  privado de `StopsMapView` devolvía un array vacío en dos situaciones distintas —no hay
  paradas aquí, y hay demasiadas para dibujarlas— y la vista adivinaba entre ellas con
  `visibleStops.isEmpty && !allStops.isEmpty`. Con esa condición, asomarse al mar o a
  Redondela pintaba "acerca el mapa para ver las paradas" sobre un sitio donde no hay
  ninguna que acercar. Ahora son dos casos de un enum y el aviso además dice cuántas hay.

  **Un intento de optimización, revertido en el acto.** La primera versión salía del bucle al
  pasar del límite y luego contaba el resto — lo que metía un `firstIndex(of:)` dentro del
  bucle, o sea O(n²) accidental, para ahorrar un filtro sobre 1149 filas. Sustituido por un
  `filter` de una pasada, con el motivo escrito en el propio fichero.

  **Verificado por mutación, cinco veces, y una se coló.** (1) "demasiadas" devolviendo lista
  vacía en vez del motivo; (2) límite exclusivo en vez de inclusivo; (3) el recuadro sin
  recortar por longitud; (4) span sin valor absoluto; (5) **media anchura sin dividir**.
  La (5) pasó desapercibida: el test del recorte usaba una parada a 20 km, que queda fuera
  con o sin el fallo, así que un error de factor 2 en el borde no lo veía nadie. Añadido
  `edgeIsHalfTheSpan`, con una parada a 600 m de un borde que está a 556 m — dentro de una
  anchura entera pero fuera de media. Con él, la mutación (5) y su gemela en longitud caen
  las dos. Es el mismo patrón que la Fase 3 documentó en su paso 3/11: los tests en verde no
  bastan si la red de pruebas no tiene la forma para exponer el fallo.

  Suite de `VigoCore`: **229 tests en verde** (+8). Debug y Release compilan.

  **Pendiente de comprobar en dispositivo** (lo hace el propietario): que el mapa arranca sin
  ninguna parada; que el conmutador las muestra y las oculta; que la preferencia sobrevive a
  matar y relanzar la app; que al alejarse sale el aviso con el número; y que tocar una
  parada sigue abriendo su detalle como antes.

- [x] **4/11 — Selección universal: parada, POI de Apple y punto suelto → `MapPlaceSheet`**
  `VigoCore/Sources/VigoCore/MapFlow/MapPlaceLabels.swift` (nuevo);
  `App/ILoveVigoRoutes/Views/Map/MapPlaceResolver.swift` y `MapPlaceSheet.swift` (nuevos),
  `MapScreen.swift` y `MapScreenModel.swift` ampliados, `DataSourcesView.swift` actualizada.
  Tests: `MapPlaceLabelsTests.swift` (8).

  Cumple la primera exigencia del propietario en su mitad de selección: **tres orígenes
  distintos entran por la misma puerta y salen como el mismo `MapPlace`**, dibujado por la
  misma ficha. Es lo que hace que "cualquier lugar disponible" sea un camino de código y no
  tres casos especiales. `mapFeatureSelectionAccessory(nil)` apaga ya la tarjeta nativa de
  Apple, que es lo que el paso 3 dejó pendiente a propósito hasta tener ficha propia.

  **"Cómo llegar" todavía no está en la ficha**, y es deliberado: llega con la hoja de ruta.
  Un botón que no lleva a ninguna parte sería peor que su ausencia durante el commit
  intermedio. Con esto la ficha ya sirve para algo por sí sola — un POI o un punto suelto se
  pueden guardar como lugar, y una parada abre sus llegadas y su estrella.

  **La tabla de categorías se genera contra el SDK, no de memoria.** Las 73 categorías de
  `MKPointOfInterestCategory.h` están traducidas, y `MapPlaceLabelsTests` fija esa misma
  lista como dato de test: si un SDK futuro añade una, sale un test rojo en vez de un lugar
  sin subtítulo que nadie nota. Una categoría desconocida **no** produce etiqueta —
  devolver `MKPOICategoryFoo` o descamelizarlo sería inventarse un rótulo en castellano a
  partir de un identificador inglés.

  **Privacidad.** `MapKitPlaceResolver` solo geocodifica un punto que el usuario ha
  mantenido pulsado a propósito: nunca la posición del dispositivo, nunca en bucle al mover
  el mapa. Devuelve un valor en vez de lanzar, porque quedarse sin nombre es normal (sin red,
  con Apple limitando, o en mitad de la ría) y no hay nada que un llamante pueda hacer
  distinto: la ficha se queda en "Punto en el mapa" y el sitio sigue siendo planificable.
  `DataSourcesView` lo dice ahora en voz alta, junto a lo que ya decía de la búsqueda de
  direcciones.

  **Detalles que sin dispositivo no se ven pero cambian el resultado:**
  - Una respuesta lenta del geocodificador **no** puede renombrar una ficha que ya no es la
    suya. `dropPin` comprueba, antes de aplicar, que el lugar seleccionado sigue siendo el
    mismo punto: pulsar dos sitios seguidos no puede acabar con el nombre del primero sobre
    la ficha del segundo.
  - Al soltar un pin se limpia la selección del mapa. Dejar un marcador de parada resaltado
    debajo de la ficha de un punto suelto es mentir sobre qué está enseñando la ficha.
  - La cámara compensa la hoja moviendo el centro **al sur**, no al norte: bajar la latitud
    del centro sube el pin en pantalla. Sin eso el sitio elegido queda detrás de la tarjeta.
  - El lugar seleccionado solo dibuja pin propio si no es ya una de las paradas de la capa,
    que si no serían dos pines en el mismo punto.

  **Verificado por mutación, seis veces.** (1) categoría desconocida devolviendo el valor
  crudo; (2) prefijo `MKPOICategory` sin recortar; (3) una categoría fuera de la tabla;
  (4) punto decimal en vez de coma; (5) metros sin redondear a decenas; (6) distancia
  negativa pintada igual. Las seis tumban tests.

  **Fallo del arnés de mutación, corregido.** La primera pasada dio la (4) por indetectada.
  No lo era: la mutación dejaba `)+ " km"`, que en Swift ni siquiera compila, y el arnés
  contaba solo marcas de test fallido — un error de compilación daba cero y se leía como
  "pasa desapercibida". Ahora distingue los dos casos, y con la mutación bien escrita la (4)
  cae. Un falso ❌ es el único error que ese arnés podía producir: un falso ✅ era imposible,
  así que las mutaciones ya dadas por buenas siguen siéndolo.

  Suite de `VigoCore`: **237 tests en verde** (+8). Debug y Release compilan.

  **Pendiente de comprobar en dispositivo:** tocar una parada con la capa encendida; tocar un
  POI de Apple **con la capa apagada** (el caso que demuestra que la selección universal no
  depende de las paradas) y ver la ficha propia y no la de Apple; mantener pulsado en mitad
  de una manzana y ver salir una dirección real; repetir en modo avión y ver "Punto en el
  mapa" sin ningún error; y comprobar que panear y hacer zoom siguen intactos con el gesto
  largo activo.

- [x] **5/11 — `MapRouteSheet`: la ruta, dentro del mapa**
  `VigoCore/Sources/VigoCore/MapFlow/CoordinateBounds.swift` (nuevo);
  `App/ILoveVigoRoutes/Views/Map/MapRouteSheet.swift` y
  `JourneyOverviewMapContent.swift` (nuevos), `MapScreen.swift`, `MapScreenModel.swift` y
  `MapPlaceSheet.swift` ampliados, `Views/JourneyTrace.swift` refactorizado.
  Tests: `CoordinateBoundsTests.swift` (7).

  **Con esto la primera exigencia del propietario está entera**: seleccionar cualquier sitio
  del mapa, pedir "Cómo llegar" y ver las alternativas con sus horas, su duración y sus
  trazados, sin salir de la pestaña Mapa.

  **Cambio de orden respecto al plan, aprobado por el propietario:** la ruta pasa a ser el
  paso 5 y la búsqueda dentro del mapa el 6. Con la selección universal ya hecha, la ruta es
  lo que completa la exigencia nº 1; buscar es un atajo para lo que ya se puede hacer tocando
  el mapa.

  **Una sola hoja para todo el flujo, conmutada por `mode`.** Presentar una segunda hoja
  encima de la primera apilaría dos tarjetas para lo que es un recorrido continuo, de "este
  sitio" a "cómo llego". El detalle por tramos **no** es una hoja nueva: es
  `JourneyDetailView` de la Fase 3 sin tocar —trazado, tramos, tiempo real del primer
  embarque y el empujón a `JourneyMapView`— empujada dentro del `NavigationStack` de la hoja
  y gobernada por `mode`, no por un `NavigationLink` suelto, para que volver atrás aterrice
  donde dice `MapNavigationState.dismiss`.

  **Los dos extremos se editan reutilizando `PlacePickerView`**, la del planificador, ya
  verificada. Cubre todas las procedencias que puede tener un extremo, y sustituirla por la
  búsqueda propia del mapa en el paso 6 es un cambio en una línea. Se resistió la tentación
  de dejar los botones vacíos "hasta el paso siguiente": un botón muerto es exactamente lo
  que este plan viene evitando en cada paso.

  **`CoordinateBounds` sale de `JourneyTraceBuilder` a `VigoCore`.** El encuadre pasa de
  enmarcar un trayecto a enmarcar **cuatro a la vez**, y ahí una unión mal hecha no es un
  detalle estético sino una ruta dibujada medio fuera de pantalla. Al mudarse queda probado:
  antes era aritmética en línea dentro de una vista, sin un solo test. `Journey.keyCoordinates`
  se queda a propósito sin los puntos del trazado, para que un trayecto se pueda encuadrar
  aunque su viaje no traiga `shape_id`, cosa que el GTFS permite.

  Decisiones menores con su razón:
  - Solo la alternativa destacada dibuja marcadores de parada. Con cuatro rutas compartiendo
    corredor, pintar todos los embarques convierte el centro de Vigo en confeti.
  - Las no seleccionadas se declaran **antes**, porque el orden de declaración es el orden de
    dibujo: así la destacada nunca queda enterrada bajo una línea gris.
  - Tocar la alternativa ya destacada la abre; tocar otra solo la destaca. El mapa se redibuja
    antes de que nadie se meta en una ruta que todavía no ha visto.
  - Los trazados de las cuatro se calculan **una vez** por resultado y fuera del hilo
    principal. Son hasta dieciséis lecturas de SQLite y no pueden ocurrir en `body`.
  - Un error lanzado por el planificador **no** se disfraza de "no hay rutas": `PlanOutcome`
    ya tiene siete formas honestas de decir lo segundo.
  - La hora de salida es un `Menu` y no un `Picker` segmentado: en una hoja el espacio
    horizontal es el recurso escaso, y ese control se toca mucho menos que los dos extremos.

  **Verificado por mutación, once veces.** Siete sobre `CoordinateBounds` —centro como media
  de los puntos en vez del recuadro, mirar solo el primero y el último, unión que se queda con
  una caja, span sin suelo, span sin margen, límites al revés sin enderezar, y un trayecto que
  olvida las paradas de sus tramos en bus— más las cuatro actualizaciones de extremo por
  separado.
  **Una se coló y hubo que reforzar el test:** "mirar solo el primero y el último" pasaba
  desapercibida porque el primer punto de la lista de prueba ya era el mínimo, así que
  olvidarse de actualizarlo no cambiaba el resultado. Reescrita con cinco puntos donde el
  primero no es extremo en ningún eje y cada uno de los cuatro extremos llega más tarde y
  desde un punto distinto; con eso caen las cuatro mutaciones de extremo, una por una. Tercera
  vez en esta fase que el mismo patrón aparece: el test verde no vale si la red de pruebas no
  tiene la forma para exponer el fallo.

  Suite de `VigoCore`: **244 tests en verde** (+7). Debug y Release compilan.

  **Pendiente de comprobar en dispositivo:** elegir un destino en el mapa y pulsar "Cómo
  llegar"; ver varias alternativas con líneas distintas; tocar cada una y comprobar que el
  trazado destacado cambia y la cámara reencuadra; tocar la destacada otra vez y ver el
  detalle por tramos; intercambiar extremos y ver que replanifica; cambiar la hora de salida;
  y comprobar el mensaje correcto con una consulta fuera de la ventana del feed.

- [x] **6/11 — Búsqueda dentro del mapa**
  `App/ILoveVigoRoutes/Views/Map/MapSearchSheet.swift` (nuevo, incluye `MapBrowseBar`);
  `MapScreen.swift`, `MapScreenModel.swift`, `MapRouteSheet.swift` y
  `MapPlaceResolver.swift` modificados; `VigoCore/MapFlow/MapPlace.swift` y
  `MapNavigationState.swift` ampliados.
  Tests: `SavedJourneyOnMapTests` (4, dentro de `MapNavigationStateTests.swift`).

  Las mismas cuatro fuentes que cubre `PlacePickerView` —paradas, direcciones, lugares
  guardados y favoritas— más los trayectos guardados, y con las mismas reglas, que ya se
  discutieron en su día y no han cambiado: la búsqueda de paradas corre en cada pulsación
  (0,2 ms contra SQLite sobre 1149 filas) y la de direcciones espera 300 ms y va siempre
  centrada en una caja fija de Vigo que nunca lleva la ubicación del usuario.

  **Lo que cambia es el destino de un resultado.** El selector del planificador tenía que
  *devolver un extremo* a un formulario. Aquí un resultado es un sitio del mapa, así que
  elegirlo abre su ficha —la misma que abre un toque en el mapa— y la ruta queda a un toque
  más. Es la forma de Apple Maps, y es lo que permite que la misma hoja sirva para "búscame
  un sitio" y para "cámbiame este extremo".

  **`PlacePickerView` sale del flujo del mapa**, tal como el paso 5 anunció: era el
  marcador de posición que funcionaba mientras la búsqueda propia no existía, y sustituirlo
  ha sido el cambio de una línea que se prometió. Sigue viva para la pestaña Planificar y
  para `SavedPlaceEditorView`. El puente `MapPlace(picked:)` que hacía falta para ella se
  queda sin usos y **se borra en el mismo commit**, en vez de quedarse ahí por si acaso.

  **La cápsula de búsqueda no es una hoja permanente**, que es la forma de Apple Maps. Una
  hoja siempre presentada taparía la barra de pestañas mientras el mapa esté abierto, y las
  otras cuatro pestañas tienen que seguir alcanzables mientras existan. Cuando "Planificar"
  desaparezca, promoverla es cambiar esta única vista.

  **Dos errores encontrados al cablearlo, los dos por no tener simulador delante sino por
  leer el código:**
  1. **La hoja se habría quedado atascada.** Cerrarla llamaba a `clearSelection()`, que por
     diseño solo actúa sobre `.place`. Arrastrarla hacia abajo estando en `.searching` —o
     mirando una ruta— habría dejado `mode` donde estaba, la binding en `true` y la hoja sin
     poder cerrarse. Ahora hay un `closeSheet()` que vale para todos los modos: una sola
     puerta de salida, el mismo argumento por el que `dismiss()` es una sola tabla.
  2. **La hoja se cerraba a sí misma y pisaba lo recién elegido.** `MapSearchSheet` llamaba a
     su `@Environment(\.dismiss)` al elegir un resultado; presentada desde el mapa eso
     desmonta la hoja en la que la ficha estaba a punto de aparecer, y compite con la
     selección que acaba de hacerse. Ahora quien presenta decide qué significa cerrar
     (`onCancel`), porque la hoja no puede saberlo: desde el mapa es una cara de una hoja que
     se queda, y desde la hoja de ruta es una hoja anidada que sí se cierra de verdad.

  **En `VigoCore`:** `MapNavigationState.route(from:to:)` para poner los dos extremos de
  golpe, y `MapPlace.savedEndpoint` / `SavedJourney.mapEnds` para traducir un trayecto
  guardado. Un extremo guardado conserva **su** nombre —"Casa", no "Rúa do Areal, 12", que
  es el motivo de haberlo guardado— y usa el nombre de la parada como subtítulo para no
  ocultar a cuál se refiere. Un extremo cuya parada ya no está en el feed sigue siendo
  planificable, que es exactamente para lo que el ancla guarda coordenada de respaldo desde
  la Fase 4.

  **Verificado por mutación, cinco veces:** (1) el extremo pierde su nombre guardado; (2) el
  subtítulo no dice de qué parada se trata; (3) un extremo suelto finge estar enlazado a un
  lugar guardado; (4) los dos extremos salen intercambiados; (5) un trayecto guardado sigue
  al GPS y deja que un fix posterior sustituya su origen. Las cinco tumban tests.

  Suite de `VigoCore`: **248 tests en verde** (+4). Debug y Release compilan.

  **Pendiente de comprobar en dispositivo:** la cápsula de búsqueda solo aparece con el mapa
  limpio; buscar "Urzáiz" y ver paradas y direcciones separadas; con el campo vacío, ver
  trayectos y lugares guardados y favoritas; elegir un resultado y aterrizar en su ficha;
  tocar un trayecto guardado y que planifique entero; cambiar un extremo desde la hoja de
  ruta; y cerrar la hoja arrastrándola hacia abajo desde **cada** uno de los modos —búsqueda,
  ficha y ruta— que es donde estaba el primero de los dos errores.

- [x] **7/11 — Tiempo real en las alternativas**
  `VigoCore/Sources/VigoCore/Planner/FirstBoardingMatch.swift` (nuevo);
  `App/ILoveVigoRoutes/Views/FirstBoardingLive.swift` (nuevo), `JourneyRows.swift`,
  `JourneyDetailView.swift`, `MapRouteSheet.swift` y `MapScreen.swift` modificados.
  Tests: `FirstBoardingMatchTests.swift` (7).

  Es lo que separa la app de un horario impreso, y lo que enseñan las capturas de referencia
  del propietario ("programado a las 22:41 desde Cno. Ronda 82", "dentro de 8, 16 min").

  **La heurística sale de `JourneyDetailView` a `VigoCore`.** Era un método privado de una
  vista; ahora la lista de rutas necesita la misma respuesta para hasta cuatro alternativas, y
  dos copias de una regla así derivan — exactamente como ya habían derivado las dos copias de
  los textos de `PlanOutcome` antes del paso 2. Al mudarse queda probada por primera vez.

  Lo que la heurística admite de sí misma, ahora escrito y con tests: la API de tiempo real
  **no tiene noción de "este viaje concreto"** —contesta línea, destino y cuenta atrás, y nada
  de eso se puede unir a un `trip_id` del GTFS—, así que el cruce es misma línea más la hora
  implícita más cercana a la salida que el planificador ya fijó, **y solo dentro de 15
  minutos**. Ese límite es lo que impide confundir el autobús que se busca con el siguiente de
  la misma línea, y hay un test en cada lado del borde.

  **Una consulta a fecha futura nunca casa**, que con este feed de siete días es el caso más
  frecuente en la práctica. Es lo correcto: el tiempo real no sabe nada de un autobús que aún
  no está por llegar, y cuando no hay coincidencia la fila no muestra **nada** — nunca una
  hora de horario con insignia de "en vivo".

  **Una petición por parada de embarque distinta, no por alternativa.** Cuatro alternativas
  salen a menudo del mismo poste, y el §8 del handoff convierte en obligación —no en detalle—
  no disparar cuatro peticiones idénticas contra unos endpoints que no tienen API oficial.
  `ThrottledRealtimeProvider` ya impone 20 s por debajo, así que agrupar aquí es no preguntar
  siquiera. Y sigue sin sondearse nunca en segundo plano: solo se pide con algo en pantalla
  que lo esté pidiendo, igual que hace `StopDetailModel`.

  El tiempo real **anota y nunca decide**: nada de esto vuelve a `RaptorEngine`. Se decidió en
  la Fase 3 y no se ha tocado.

  **Verificado por mutación, seis veces:** (1) sin límite de tolerancia; (2) sin filtrar por
  línea; (3) comparando la línea en crudo en vez de normalizada; (4) cogiendo la primera
  llegada en vez de la más cercana; (5) la distancia ignorando los minutos de la llegada;
  (6) `firstRide` devolviendo el último tramo en bus en vez del primero. Las seis tumban
  tests — la (6) tras reescribirla, porque la primera versión de esa mutación ni siquiera
  compilaba.

  Suite de `VigoCore`: **255 tests en verde** (+7). Debug y Release compilan.

  **Pendiente de comprobar en dispositivo:** con una consulta "ahora" y dentro de la ventana
  del feed, que alguna alternativa muestre "sale en N min" con su insignia de procedencia; que
  las que no casan no muestren nada en absoluto; y que el detalle del trayecto siga anotando
  igual que antes de este paso.

- [x] **8/11 — Estados de borde y accesibilidad**
  `VigoCore/Sources/VigoCore/MapFlow/JourneySummary.swift` (nuevo);
  `App/ILoveVigoRoutes/Views/JourneyRows.swift`, `Map/MapPlaceSheet.swift`,
  `Map/MapRouteSheet.swift`, `Map/MapScreen.swift` y `Map/MapScreenModel.swift` modificados.
  Tests: `JourneySummaryTests.swift` (7).

  **VoiceOver.** `JourneyAlternativeRow` ya se colapsaba en un solo elemento, pero sin
  etiqueta propia se leía la pila tal como estaba puesta: dos horas sueltas, un número, y una
  insignia de línea que es un dígito sin sustantivo delante ("17"). `JourneySummary.spoken`
  arma la frase que diría una persona —"Sale a las 15:33, llega a las 15:51, 18 minutos,
  directo, línea 17."— con singulares y plurales correctos. Está en `VigoCore` y recibe
  locale y zona horaria como parámetros, así que se comprueba con `swift test` en vez de
  quedar para mirarlo en el dispositivo.
  La **procedencia del tiempo real va dentro de la frase** ("en vivo" / "estimado"): la
  insignia que la muestra no tiene texto propio, así que sin eso quien usa VoiceOver no puede
  distinguir un vehículo seguido de una estimación. Y sin anotación no se insinúa que la haya.

  **"Cómo llegar" se deshabilita con su motivo a la vista**, no en silencio: mientras el feed
  se está importando, y cuando no hay ni ubicación ni origen elegido. Se comprueba **antes**
  de pulsar, en vez de dejar que el botón parezca vivo, gire y luego se explique.

  **Reduce-motion.** Todos los movimientos de cámara pasan ahora por un único `move(to:)` que
  desactiva la animación cuando el sistema la ha pedido reducida. Uno solo, en vez de
  acordarse en cada sitio que mueve la cámara.

  **Sin ubicación**, la hoja de ruta lo dice en su pie en lugar de dejar una fila vacía que el
  usuario tenga que adivinar. El mapa sigue abriendo en Praza de América, que nunca se
  presenta como la posición del usuario.

  **Verificado por mutación, siete veces:** (1) la línea leída como número suelto; (2) la
  procedencia del tiempo real desaparecida; (3) un trayecto a pie hablando de líneas y horas;
  (4) transbordo siempre en plural; (5) minuto siempre en plural; (6) duración negativa leída
  tal cual; (7) solo la primera línea nombrada en un trayecto con transbordo. Las siete tumban
  tests — la (7) tras reescribirla, porque la primera versión no compilaba.

  Suite de `VigoCore`: **262 tests en verde** (+7). Debug y Release compilan.

- [x] **9/11 — Documentación y criterio de retirada**
  `ESTADO.md`, `README.md`.
  Los pasos 10 y 11 del plan se funden aquí: escribir el estado y dejar por escrito **cuándo**
  se puede borrar la pestaña "Planificar" es el mismo trabajo, y separarlos habría sido un
  commit de una línea.

**Fase 5 completa — 9 pasos.** El mapa es el planificador: selección universal (parada, POI de
Apple, punto mantenido pulsado, búsqueda), ruta con hasta cuatro alternativas, trazados,
detalle por tramos, navegación, tiempo real del primer embarque, y las paradas convertidas en
una capa apagada por defecto. Commits `5c5ce4c`..`HEAD` en `main`.

**Lo que esta fase deja anotado sobre cómo se ha verificado.** Desde el paso 0 el propietario
prueba **solo en dispositivo**, sin simulador. Eso ha empujado casi toda la lógica nueva a
`VigoCore` —máquina de estados, mensajes, capa de paradas, etiquetas, encuadre, cruce con
tiempo real, resumen hablado— donde `swift test` la cubre en el Mac. No fue una concesión: la
partición cayó donde ya estaba la costura, y lo que se quedó en el target de app es justo lo
que no es función pura del estado.
Se aplicaron **48 mutaciones deliberadas** a lo largo de la fase. **Tres pasaron
desapercibidas** y obligaron a reforzar la red de pruebas antes de seguir: media anchura del
recuadro sin dividir (paso 3), mirar solo el primero y el último punto al calcular límites
(paso 5), y —fuera de la cuenta— un fallo del propio arnés, que contaba un error de
compilación como mutación indetectada (paso 4). El patrón se repitió lo bastante como para
dejarlo escrito: **un test con datos cómodos no ve la mitad de los fallos**; en los tres casos
el dato de prueba estaba tan lejos del borde que romper la aritmética no cambiaba el
resultado.

## Fase 6 — El mapa, sin la muleta anterior

Plan en `~/.claude/plans/listo-todo-probado-tenemos-luminous-rivest.md`. Nace de la prueba en
dispositivo de la Fase 5 (iPhone 17 Pro Max, Release, 2026-09-05): el flujo funcionaba, pero
la fase se había construido **sin retirar lo viejo**, y la prueba destapó tres defectos de
interacción.

### Hecho

- [x] **El botón de "mi ubicación" no estaba roto: estaba tapado.**
  `MapUserLocationButton` vivía dentro de `.mapControls`, cuya posición decide MapKit, y
  encima había un `.overlay(alignment: .topTrailing)` propio para el conmutador de capas,
  empujado con un `.padding(.top, 54)` puesto a ojo. Los dos caían en la misma esquina y el
  overlay, que se dibuja por encima, **se comía el toque**: el gesto no llegaba nunca. No era
  un fallo de la cámara, y por eso ajustar el padding no habría arreglado nada.
  Ahora los dos botones son nuestros y viven en un único `VStack`, así que sus posiciones no
  pueden discrepar. `.mapControls` se queda solo con `MapScaleView` (abajo a la izquierda, sin
  colisión posible) y **se retira `MapCompass`**, que vuelve a esa misma esquina en cuanto el
  mapa se rota. De paso, el botón propio puede deshabilitarse y explicarse sin permiso de
  ubicación, cosa que el de MapKit no hace.

- [x] **La ficha abre mostrando sus acciones.**
  `presentationDetents` sin `selection:` abre en el detente **más pequeño**, y el más pequeño
  aquí era el de 180 pt que solo enseña el título: cada ficha llegaba con "Cómo llegar" y
  "Guardar" escondidos tras un arrastre que el usuario no tenía por qué hacer. Con la binding
  puesta, cada modo entra por la altura que le corresponde —ficha y ruta a 0,45, búsqueda a
  `.large`, seguimiento al mínimo— y el detente pequeño sigue existiendo para bajarla a mano.

- [x] **El mapa abre la app.** `RootView`: `selection = .map`. El criterio de la Fase 1 —ver
  las llegadas de una favorita en un toque o ninguno desde arranque en frío— sigue en pie:
  Favoritas queda a un toque, y el mapa contesta la pregunta que trae a alguien a la app.

- [x] **Muere la pestaña "Planificar".** Los once puntos de paridad quedaron comprobados en
  dispositivo, que era la condición escrita. Fuera `.planner` de `AppTab`,
  `Views/PlannerView.swift` y `ILoveVigoRoutesTests/PlannerModelTests.swift`. Quedan cuatro
  pestañas: Mapa · Favoritas · Buscar · Cercanas.
  **`PlacePickerView` sobrevive**, con `PickedPlace` y `MapPointPickerView`: las usan
  `SavedPlaceEditorView` y `SavedJourneyEditorView`, que no son parte del flujo del mapa.
  Comprobado por `grep` antes de borrar, no supuesto.

- [x] **El detalle del trayecto deja de ser pantalla aparte.** Borradas
  `Views/JourneyDetailView.swift` y `Views/JourneyMapView.swift`. Con el mapa a pantalla
  completa detrás de la hoja, un minimapa no interactivo dentro de una lista que empujaba a
  otro mapa era un rodeo para volver a donde ya estabas. Los tramos pasan a
  `MapJourneyLegsView`, un nivel más de `MapRouteSheet`, reutilizando `JourneyLegRow` sin
  tocarla; la anotación en vivo la sirve `FirstBoardingLive`, que ya la calculaba, en vez de
  repetir la consulta.

- [x] **El seguimiento se salva y sube al mapa principal.** Lo que `JourneyMapView` aportaba
  de verdad no era el mapa —eso ya lo había— sino tres cosas que sí se habrían perdido:
  cámara con rumbo, pantalla que no se apaga mientras caminas, y precisión `Best` en vez de
  los cien metros que bastan para "qué paradas tengo cerca". Ahora es `isFollowing` en
  `MapNavigationState`, con sus reglas en `VigoCore` y no en la vista: seguir solo tiene
  sentido con un trayecto abierto; `dismiss()` **sale del seguimiento antes** de retroceder de
  nivel, porque quien toca atrás con la cámara persiguiéndole quiere que deje de perseguirle,
  no cerrar el trayecto; y destacar otra alternativa, editar un extremo, replanificar o cerrar
  la hoja lo apagan. `MapScreen` restaura el autobloqueo también en `onDisappear`: irse de la
  pestaña no puede dejar la pantalla clavada encendida.
  **Verificado por mutación, siete veces**, una por regla. Las siete tumban tests.

- [x] **Favoritas salta al mapa.** Tocar un trayecto guardado empujaba `JourneyDetailView`.
  Ahora es una petición: `AppEnvironment.requestOnMap(_:)`, `RootView` cambia de pestaña y
  `MapScreen` la consume **y la limpia** —sin eso, volver al mapa más tarde replanificaría
  un trayecto que nadie pidió—. Con ello **se borra `SavedJourneyPlanModel`** y su traducción
  propia de `PlanOutcome`: planificar deja de ocurrir en dos sitios.

**Un tropiezo de entorno, no de código.** A mitad de la fase `xcodebuild` empezó a decir
*"iOS 26.5 is not installed"* y dejó de resolver el destino, después de haber compilado bien
media hora antes. Era Xcode, que estaba abierto e indexando tras haber añadido la cuenta de
firma; cerrándolo, todo volvió a compilar sin descargar nada. Queda anotado porque el mensaje
de error apunta a una descarga de plataforma que no hacía ninguna falta.

Suite de `VigoCore`: **273 tests en verde** (+8). Tests del target de app: bajan de 23 a 17 al
irse `PlannerModelTests`. Debug y Release compilan, y la app está instalada en el dispositivo.

## Retirada de la pestaña "Planificar"

**Hecha en la Fase 6.** Se conserva la lista de paridad por la que se autorizó, como registro
de qué tenía que cumplir el mapa antes de que la pestaña pudiera desaparecer.

1. Origen por ubicación que sigue al GPS hasta que se toca. ✅ implementado
2. Origen y destino intercambiables. ✅
3. Salida "ahora" y a una hora concreta. ✅
4. Elegir extremo: ubicación, parada favorita, búsqueda de parada, dirección, punto del mapa,
   lugar guardado, trayecto guardado. ✅
5. Hasta 4 alternativas con horas, duración y transbordos. ✅
6. Los 8 casos de `PlanOutcome` con su texto. ✅ (`PlanOutcomeMessage`, compartido)
7. Detalle por tramos. ✅ (`JourneyDetailView`, reutilizada sin tocar)
8. Trazado real en el mapa. ✅
9. Tiempo real del primer embarque. ✅
10. Guardar el trayecto planificado. ✅
11. Empujar a `JourneyMapView`. ✅ (desde `JourneyDetailView`)

- [x] **Guardar un trayecto desde la hoja de ruta** — cerraba el único hueco de la lista.
  `VigoCore/MapFlow/MapPlace.swift` gana `savedEndpointInput`;
  `App/ILoveVigoRoutes/Views/SavedJourneyEditorView.swift` gana un modo `.createFrom` con los
  dos extremos ya puestos; `Map/MapRouteSheet.swift` añade el botón.
  Tests: `SavedEndpointInputFromMapPlaceTests` (3, en `MapNavigationStateTests.swift`).

  `.createFrom` es un caso propio y no un `.create` con argumentos opcionales, para que
  `canSave` siga significando "los dos extremos están puestos" sin una segunda manera de
  quedarse a medias.

  La conversión de `MapPlace` a extremo guardado respeta las dos reglas que la Fase 4 fijó y
  que solo se notan tras una reimportación: una parada se guarda por **`stopID` más coordenada
  de respaldo**, nunca como un `Stop` —el importador reescribe esa tabla entera cada semana—, y
  un extremo que venía de un lugar guardado se queda **enlazado**, de modo que renombrar "Casa"
  más tarde lo renombra también aquí. Todo lo demás (una dirección, un punto pulsado, un POI)
  es ad hoc por definición: no hay lugar guardado al que seguir.

  El botón va **el último** de la hoja, no el primero: lo que se ha venido a ver son las
  alternativas, y un trayecto merece guardarse una vez comprobado que es el bueno. El pie dice
  en voz alta qué se guarda —el par origen–destino, no el autobús concreto— porque guardar "el
  17 de las 9:02" sería una promesa que el horario no puede repetir mañana.

  **Verificado por mutación, tres veces:** (1) una parada anclada por coordenada en vez de por
  id; (2) un lugar guardado que deja de estar enlazado; (3) todo enlazado a un lugar inventado.
  Las tres tumban tests.

  Suite de `VigoCore`: **265 tests en verde** (+3).

**Cuando las once estén:** quitar `.planner` de `AppTab`, borrar `PlannerView.swift` y
`App/ILoveVigoRoutesTests/PlannerModelTests.swift`.

## Fase 7 — Un solo buscador, dos pestañas

Una auditoría externa señaló que `PlacePickerView` y `MapSearchSheet` eran casi el mismo
buscador —paradas contra SQLite por pulsación, direcciones con debounce de 300 ms, lugares
guardados, trayectos guardados, favoritas— ya divergiendo en comportamiento, y que el propio
código anticipaba absorber también las pestañas Buscar y Cercanas en el mapa. Son dos
trabajos independientes: `PlacePickerView` no lo usaba ninguna pestaña, sino los dos
editores de Favoritas.

**Paso 1 — llegadas en la ficha de lugar del mapa.** Prerrequisito de todo lo demás: sin
esto, absorber Cercanas habría convertido un toque en tres. `StopArrivalsSummary` y
`StopArrivalsFeed` (nuevos, `App/ILoveVigoRoutes/Views/`) se extraen de
`FavouriteStopCard`; `MapPlaceSheet` los usa para mostrar los próximos pasos de una parada
sin pasar por `StopDetailView`, cuyo enlace pasa a llamarse "Ver horario y detalles".

**Paso 2 — `PlacePickerView` eliminado.** `PlacePickerRole` se mueve a su propio fichero
(`Map/PlacePickerRole.swift`) para que `MapSearchSheet` no dependa del tipo que va a
desaparecer. `MapSearchSheet.Purpose` gana `.standalone(title:)`; el sheet añade "Mi
ubicación", "Elegir en el mapa" (en los tres propósitos, incluido `.explore` — es la ruta
accesible a "soltar un pin en cualquier sitio", que la pulsación larga del mapa no ofrece a
VoiceOver) y el swipe "Guardar" en filas de parada y dirección. `SavedPlaceEditorView` y
`SavedJourneyEditorView` pasan a usar `MapSearchSheet(purpose: .standalone(...))`; de paso,
`EndpointPickerSheet` deja de forzar `.adHoc` en todo lo que elegía —perdiendo el enlace vivo
a un lugar guardado— y usa `MapPlace.savedEndpointInput`, que ya aplicaba las reglas
correctas y nadie llamaba desde aquí.

**Paso 3 — "Cerca de ti" y "Líneas con servicio".** Dos secciones nuevas en el estado vacío
de `MapSearchSheet`: la primera con `nearbyStops` a radio fijo de 800 m (sin selector — tenía
sentido como pantalla entera, no como sección de un sheet), la segunda con
`routesWithService`, filas no interactivas porque no existe consulta stopID-por-routeID en
el repositorio para filtrar la capa de paradas por línea. Ambas cargan fuera del main actor
con `Task.detached`; la de cercanía usa `.task(id:)` sobre una coordenada redondeada a
~11 m para no relanzar la consulta en cada jitter de GPS. La búsqueda con texto matchea
también nombres de línea, no solo códigos de parada.

**Paso 4 — fuera las pestañas Buscar y Cercanas.** Ambas eran subconjuntos de lo que
`MapSearchSheet` ya cubría. Quedan dos pestañas: Mapa y Favoritas. `nearbyStops`,
`NearbyStop` y `routesWithService` se quedan en `VigoCore` — los usa `JourneyPlanner` y
`TimetableBuilder` además del propio buscador.

Neto: −255 líneas aproximadamente, un buscador en vez de dos, un hueco de accesibilidad
cerrado y un bug de "Duplicar"/edición de trayectos corregido de paso. 273 tests de
`VigoCore` sin cambios (esta fase no toca el paquete); 16 tests del target de app en verde.

## Fase 8 — Las caminatas en el mapa y actualizar a mano

Plan en `PLAN-FASES-8-13.md`, §Fase 8. Nace de la prueba en dispositivo del 2026-09-05, tras
fusionar la Fase 7: tres cosas que el propietario echó en falta usando la app de verdad. No es
funcionalidad nueva, son defectos de lo ya entregado.

Ese mismo documento **renumera** las cuatro fases que ya estaban planificadas y sin escribir
(ordenación 8→10, trayecto activo 9→11, recientes 10→12, avisos 11→13) para meter delante esta
y la 9. Renumerar era gratis mientras ninguna estuviera anotada aquí, y dejaba de serlo en cuanto
la primera se implementara.

### Hecho

- [x] **1/3 — `Journey.walkSegments` y `FirstBoardingMatch.hasDeparted`, en `VigoCore`**
  `VigoCore/Sources/VigoCore/MapFlow/JourneyWalkSegments.swift` (nuevo),
  `Planner/FirstBoardingMatch.swift`; tests en `JourneyWalkSegmentsTests.swift` (3) y
  ampliación de `FirstBoardingMatchTests.swift` (2).

  Las dos piezas puras de la fase, en el paquete y no en la app, por la razón de siempre desde
  la Fase 5: ahí las cubre `swift test` en el Mac.

  `hasDeparted` se mide contra el **embarque**, no contra `Journey.departure`. No son el mismo
  instante y solo uno es el autobús: `departure` es cuándo habría que echar a andar hacia la
  parada, anterior por toda la caminata de acceso. Compararla daría el trayecto por perdido con
  el autobús aún sin pasar, y es exactamente la misma distinción que §10.1 del plan tiene que
  hacer entre "sale antes" y la hora a la que se cierra la puerta.

  **Verificado por mutación, cinco veces:** (1) los tramos a pie sin geometría —el defecto
  original—; (2) `from` y `to` invertidos; (3) los de longitud cero dibujados; (4) `hasDeparted`
  contra `departure`; (5) un trayecto solo a pie contando como salido. Las cinco tumban tests.

  **Un fallo del arnés de mutación, otra vez, y distinto del de la Fase 5.** La mutación (1)
  se dio primero por indetectada y luego por "no compila": ninguna de las dos cosas era cierta.
  Compilaba, y el test caía con un `Fatal error: Index out of range` al indexar `segments[0]`
  tras un `#expect` de cuenta que ya había fallado — y el arnés buscaba `error:` en la salida,
  que un crash también imprime. Corregido en los dos lados: el arnés compila primero y solo
  entonces distingue fallo de crash, y los dos tests pasan a usar `try #require` para la cuenta,
  de modo que una cuenta equivocada da un test rojo en vez de reventar la suite entera. Un
  `crash` se lee mucho peor que un fallo, y aquí además escondía qué mutación lo había causado.

- [x] **2/3 — El mapa dibuja las caminatas**
  `App/ILoveVigoRoutes/Views/JourneyTrace.swift`, `Views/Map/JourneyOverviewMapContent.swift`.

  `JourneyTraceBuilder` hacía `guard case .ride(…) else { continue }`, así que **ningún** tramo a
  pie producía geometría: el trazado del autobús flotaba sin unirse ni al pin de origen ni al de
  destino, y un trayecto `walkOnly` —que no tiene ningún `.ride`— no dibujaba **nada**, dos
  marcadores y un hueco entre ellos. En la lista de tramos sí salían, y siguen saliendo igual:
  `JourneyLegRow` ya dibujaba el caso `.walk` con sus metros y minutos. El defecto era solo del
  mapa.

  Discontinuas y del mismo índigo. **Descartado `MKDirections`**: daría la acera de verdad a
  cambio de una petición de red por tramo a pie y por alternativa —hasta ocho— con las dos
  coordenadas saliendo del dispositivo en cada replanificación, y este proyecto solo geocodifica
  cuando el usuario pulsa un sitio a propósito (`MapKitPlaceResolver`, Fase 5 paso 4). La recta
  no es una aproximación vergonzante: es lo que la app ya afirma en palabras en cada tramo ("en
  línea recta") y lo que `NearbyStop.distanceMetres` está documentado como ser. La discontinuidad
  dice en el dibujo lo mismo que el texto; una línea continua sobre la acera equivocada sería la
  mentira.

  Solo la alternativa destacada dibuja sus caminatas — la misma regla que ya regía los marcadores
  de parada desde la Fase 5, y aquí pesa más: los tramos de acceso de las cuatro alternativas
  salen todos del mismo origen, en abanico.

- [x] **3/3 — Actualizar a mano, edad de la respuesta y "Ya ha salido"**
  `App/ILoveVigoRoutes/Views/Map/MapScreenModel.swift`, `Map/MapRouteSheet.swift`,
  `Map/MapScreen.swift`, `Views/JourneyRows.swift`.

  Los únicos disparadores de replanificación eran editar un extremo, intercambiarlos o cambiar la
  hora de salida. Si se escapaba el autobús recomendado no había gesto para ver el siguiente.
  Ahora `.refreshable` **y** botón en la barra: los dos, porque tirar hacia abajo es invisible y
  la hoja abre en un detente donde no siempre hay recorrido para el gesto. El botón va en la
  barra y no en la cabecera de "Alternativas" porque ahí entra el menú de ordenación de la
  Fase 10.

  **Nada se replanifica solo.** Un recálculo automático movería la lista bajo el dedo y podría
  cambiar la alternativa destacada mientras se está leyendo. Se dice la edad de la respuesta y se
  ofrece el gesto. La edad solo con salida "ahora": un trayecto pedido para una hora fija no
  envejece, y fecharlo invitaría a una actualización que no puede devolver nada distinto.

  "Ya ha salido" atenúa la fila pero **no la esconde**: un autobús que se ha ido sigue siendo la
  respuesta a lo que se preguntó, y quitar filas bajo el dedo es peor que atenuarlas. En VoiceOver
  va **delante** de la frase, no detrás de una lista de horas, y calla el tiempo real de un
  autobús que ya no está por venir.

  **El tiempo real no se fuerza.** La caché de 20 s de `ThrottledRealtimeProvider` no se saltea:
  esos endpoints no tienen API oficial y el §8 del handoff lo convierte en obligación. Dentro de
  la ventana se sirve lo cacheado, y ningún texto promete lo contrario.

  **Arreglo de camino: el trazado ya no parpadea.** `plan()` vaciaba las trazas antes de
  consultar y el mapa dibujaba desde `state.route.journeys`, que se vacía al empezar la consulta;
  la ruta que se estaba mirando desaparecía durante toda la replanificación. Ahora el mapa dibuja
  de `MapScreenModel.drawn`, un par (trayectos, trazas) con **un único escritor**, sustituido solo
  cuando hay algo nuevo con lo que sustituirlo. Que el mapa esté en la ruta lo decide el modo, así
  que cerrar la hoja se la sigue llevando.
  El encuadre pasa a colgar de ese par y no del estado, y eso arregla un segundo fallo que estaba
  ahí sin verse: colgado de `state.route.journeys` se disparaba mientras `drawn` aún tenía el
  resultado anterior, encuadrando una ruta con la geometría de otra.

**Fase 8 completa — 3 pasos.** Suite de `VigoCore`: **278 tests en verde** (+5). Target de app:
**16 tests en verde**, sin cambios. Debug y Release compilan contra `generic/platform=iOS`.

**Comprobado en dispositivo por el propietario** (2026-09-05), los ocho puntos:

- [x] Un trayecto con bus: se ven las dos rectas discontinuas, del origen a la parada y de la
      bajada al destino
- [x] Un destino tan cerca que sale `walkOnly`: **ahora se dibuja algo**, que antes no pasaba
- [x] Con cuatro alternativas, solo la destacada dibuja sus caminatas
- [x] Dejar pasar la hora de un autobús: la fila dice "Ya ha salido" sin tocar nada
- [x] Actualizar, con el botón y tirando hacia abajo: sale el siguiente y el trazado no parpadea
- [x] El pie dice a qué hora se calculó, y con hora fija de salida no lo dice
- [x] La línea discontinua se distingue de la continua a la escala a la que abre el mapa
- [x] El botón de actualizar no queda debajo del pulgar del gesto de arrastrar la hoja









## Verificación rápida del estado

```bash
cd VigoCore && swift test 2>&1 | tail -3
xcodebuild -scheme ILoveVigoRoutes -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
git log --oneline -5
```
Al escribir este documento: **311 tests de `VigoCore` en verde** (170 antes de la Fase 4;
+24 en la Fase 4 entre `SavedPlacesTests`, `MigrationTests` y `RepositoryTests`; +71 en la
Fase 5 entre `MapNavigationStateTests`, `PlanOutcomeMessageTests`, `MapStopsLayerTests`,
`MapPlaceLabelsTests`, `CoordinateBoundsTests`, `FirstBoardingMatchTests` y
`JourneySummaryTests`; +5 en la Fase 8 entre `JourneyWalkSegmentsTests` y la ampliación de
`FirstBoardingMatchTests`; +13 en la Fase 9 entre `DepartureBoardTests` y
`LineTimetableQueryTests`; +20 en la Fase 10 entre `JourneyOrderingTests`,
`EgressCandidatesTests` y `MapOrderingTests`), incluida la suite del feed real con `VIGO_GTFS_ZIP`
apuntando al archivo publicado, y **16 tests del target de app** (eran 23 hasta que la Fase 6 se llevó
`PlannerModelTests` con la pestaña que probaba; la cifra de 17 que este documento citaba
después de la Fase 6 no coincide con lo que arroja `xcodebuild test` hoy — ni `PlacePickerView`
ni ninguna vista tocada en la Fase 7 tenían tests propios, así que la diferencia es anterior
a esta fase).

Desde la Fase 5 el propietario prueba **solo en dispositivo**, no en simulador. Aquí se
verifica con `swift test` (que corre en el Mac) y con compilación contra
`generic/platform=iOS`; los tests del target de app requieren simulador y por tanto los
ejecuta él. Es la razón por la que la lógica nueva del mapa vive en `VigoCore` y no en la
app.

## Fase 9 — Todos los horarios de una línea en una parada

Plan en `PLAN-FASES-8-13.md`, §Fase 9. La otra mitad de "¿y el siguiente?": la Fase 8 vuelve a
preguntar por ti, esta enseña la tabla entera para que no haga falta preguntar. El caso que la
motiva, tal cual lo dio el propietario: Reiseñor 12 → Alcampo devuelve C3D, 15A, 4C y **otra vez
C3D**, dos alternativas de la misma línea a horas distintas — exactamente lo que una tabla de
horarios colapsa en una sola lista legible.

### Hecho

- [x] **1/2 — La consulta, `DepartureBoard` y `serviceDays`, en `VigoCore`**
  `VigoCore/Sources/VigoCore/Departures/DepartureBoard.swift` (nuevo),
  `Persistence/TransitRepository.swift`; tests en `DepartureBoardTests.swift` (6) y
  `LineTimetableQueryTests.swift` (7).

  `scheduledDepartures(stopID:routeID:on:)` es la hermana de la que ya existía. Aquella contesta
  "qué viene pronto" —todas las líneas, tres horas, treinta filas—; esta contesta "cuándo pasa
  esta línea por aquí", que necesita el día entero y no lleva tope: una línea cargada son 60–80
  filas.

  Pide **los dos días de servicio**, no solo el que se nombra. Un viaje que sale a las 25:10
  pertenece al día de servicio anterior pero ocurre a la 01:10 de este, y quien lee la tabla lo
  espera bajo el día en que estará en la parada. El fixture ya traía ese caso desde la Fase 0
  (`T_NIGHT_1`), así que el test no hubo que inventarlo.

  `DepartureBoard` separa los sentidos y marca la siguiente. Lo primero es la diferencia entre
  una tabla y una lista de números: una parada servida en las dos direcciones, en una sola
  columna, no significa nada. Lo segundo es que "la siguiente" es la primera **posterior a
  `now`** y no la primera de la lista — a las 20:00 la cabeza de la tabla es el autobús de las 6
  de la mañana.

  `FeedStatus.serviceDays` da los días que el feed puede contestar. No es lo mismo que siete días
  desde hoy, y a veces es lo contrario: el feed real descargado el 2026-09-04 reportaba ventana
  20260905–20260911, que **empieza mañana**, así que hasta "hoy" puede caer fuera.

  **Verificado por mutación, seis veces:** (1) preguntar solo por el día nombrado; (2) sin filtro
  por línea; (3) bordes con 86400 fijo en vez de medianoches reales; (4) los días del selector
  desde el reloj; (5) la siguiente como la primera de la lista; (6) los dos sentidos en una
  columna.

  **La (3) pasó desapercibida**, y es la cuarta vez que este proyecto anota el mismo patrón: el
  fixture vive entero en septiembre y no cruza ningún cambio de hora, así que 86400 y la
  distancia real entre dos medianoches coinciden siempre. Añadido un feed mínimo alrededor del
  **domingo 25 de octubre de 2026**, que dura 25 horas: una salida a las 24:30 de ese día ocurre
  media hora antes de la medianoche del 26 y pertenece a la tabla del 25; con 86400 fijo se cae
  de esa tabla y aparece un día tarde. Con ese test, la (3) tumba tres.

  De paso, un test asertaba `ServiceTime.seconds` creyendo que eran los segundos del día. Son los
  del minuto, y compilaba igual diciendo otra cosa; pasa a asertar sobre el instante.

- [x] **2/2 — `LineTimetableView` y el enlace desde el tramo en bus**
  `App/ILoveVigoRoutes/Views/LineTimetableView.swift` (nuevo, incluye `FeedCoverageNote`),
  `Views/JourneyRows.swift`.

  Alcance a propósito: **una línea, una parada, un día**, y no la tabla completa de la línea en
  todas sus paradas. Eso es un horario impreso, no una respuesta; lo que resuelve la duda real
  ("¿cuándo pasa el siguiente por *aquí*?") es la columna de esta parada.

  Secciones por sentido, la próxima salida marcada y la lista abierta ya desplazada hasta ella.
  Selector de día acotado a `serviceDays`, que arranca en hoy solo si el feed lo cubre. Arriba,
  el tiempo real de esa línea filtrado por nombre normalizado, reutilizando la misma llamada a
  `ArrivalsService` que ya hacen `StopDetailView` y la ficha del mapa: **ni un tipo de petición
  nuevo**, y con el límite de 20 s intacto por debajo.

  La lectura va fuera del actor principal, como el resto de consultas de esta app: 60–80 filas de
  SQLite sin punto de suspensión propio donde ceder.

  El fichero nuevo hubo que **darlo de alta a mano en `project.pbxproj`** (cuatro sitios: build
  file, file reference, grupo y fase de compilación). El proyecto no usa grupos sincronizados con
  el sistema de ficheros, así que un `.swift` nuevo no entra solo y el error que da —"cannot find
  X in scope"— no apunta a la causa.

**Fase 9 completa — 2 pasos.** Suite de `VigoCore`: **291 tests en verde** (+13). Target de app:
**16 tests en verde**, sin cambios. Debug y Release compilan contra `generic/platform=iOS`.

**Comprobado en dispositivo por el propietario** (2026-09-05), los seis puntos:

- [x] Desde un tramo en bus se llega a los horarios de esa línea en esa parada
- [x] La lista abre por la próxima salida, no por las 6 de la mañana
- [x] Una parada con los dos sentidos: dos secciones, no una columna mezclada
- [x] Una línea nocturna: las salidas de después de medianoche aparecen en el día correcto
- [x] El selector de día solo ofrece los días que el feed cubre
- [x] La tabla se lee de un vistazo en la pantalla del iPhone

## Fase 10 — Criterio de ordenación de alternativas

Plan en `PLAN-FASES-8-13.md`, §Fase 10. Tres criterios en un menú, con **«Menos caminata» por
defecto**. Depende de la Fase 8: un criterio que ordena por la caminata final es indemostrable
mientras el mapa no dibuje ninguna caminata.

### Hecho

- [x] **1/2 — El motor: candidatos de bajada, cuatro ejes y `JourneyOrdering`**
  `VigoCore/Sources/VigoCore/Planner/JourneyOrdering.swift` y `JourneyShortlist.swift` (nuevos),
  `JourneyReconstruction.swift`, `JourneyPlanner.swift`, `PlannerOptions.swift`;
  tests en `JourneyOrderingTests.swift` (11) y `EgressCandidatesTests.swift` (4).

  **El problema de fondo no era ordenar.** Al hacer «menos caminata» el criterio por defecto,
  deja de bastar con reordenar: hay que asegurarse de que la alternativa que menos te hace andar
  **llegue a existir**, y no existía, por dos motivos independientes.

  1. `bestEgress` elegía **una** parada de bajada por ronda: la de llegada mínima. Una parada
     que te deja a 100 m del portal pero a la que el bus llega tres minutos más tarde no se
     filtraba después — no se generaba. Ahora `egressCandidates` devuelve el frente de Pareto
     sobre (llegada, caminata final), acotado a `maxEgressCandidates` (3), y **el recorte del
     frente se hace por los dos extremos**: su cola es justo el candidato que todo esto existe
     para producir.
  2. El filtro de dominadas miraba tres ejes y no conocía la caminata, así que descartaba
     exactamente ese candidato antes de que nadie pudiera ordenarlo. Es el caso literal del plan:
     X (llega 9:40, 1 transbordo, 2 min a pie) contra Y (llega 9:38, 0 transbordos, 15 min a
     pie) — Y ganaba en los tres ejes y X, que era la respuesta bajo «menos caminata»,
     desaparecía. `JourneyShortlist.undominated` añade el cuarto eje.

  Coste honesto y aceptado: un eje más significa menos dominancia y un frente mayor. Por eso
  `maxCandidates` (8) es mayor que `maxAlternatives` (4), y por eso el corte **no puede ser «los
  primeros por llegada»** — eso metería el criterio antiguo por la puerta de atrás, dejando un
  menú que reordena opciones elegidas todas por rapidez. `JourneyShortlist.cut` reparte por
  turnos entre criterios, lo que garantiza que el óptimo de cada uno sobrevive.

  `JourneyOrdering` fija los tres criterios con sus desempates. «Sale antes» se mide sobre el
  **embarque** y no sobre `Journey.departure`, que es cuándo hay que echar a andar y difiere por
  alternativa; «llega antes» reproduce exactamente el orden anterior a esta fase, desempate
  invertido de la salida incluido, y hay un test dedicado a decirlo.

  **Un fallo latente encontrado de camino:** `reconstruct` suponía al menos un tramo en bus
  (`rides[rides.count - 1]`), y un candidato de bajada alcanzable **sin coger nada** lo habría
  reventado. No es hipotético: pasa cuando origen y destino están cerca, porque entonces una
  misma parada está en la lista de acceso y en la de salida. Ahora devuelve `nil` y el llamador
  lo salta.

  **Verificado por mutación, quince veces.** Entre ellas: una sola parada de bajada (el
  comportamiento anterior), el frente sin filtrar, dominadas con tres ejes, corte por llegada,
  «menos caminata» implementada como duración, «sale antes» sobre `departure`, el desempate de
  «llega antes» invertido, la caminata final buscando el último tramo *entre paradas*, cortar
  antes de ordenar, y el índice de la alternativa sobreviviendo a un reorden.

  **Una pasó desapercibida** —el recorte del frente por la cabeza—, y por la razón de siempre:
  mi frente de prueba tenía dos miembros, y con dos, recortar por la cabeza y recortar por los
  extremos dan lo mismo. Reescrito con tres (B a las 08:10, C a las 08:20 y D a las 09:40, con
  caminatas de 500, 120 y 30 s: llegadas crecientes y caminatas decrecientes, así que los tres
  están en el frente). Con él, la mutación tumba tres tests. Quinta vez que este documento anota
  el mismo patrón.

  **Dos tests existentes se rompieron, y era lo esperado (R2 del plan).** Los dos fijaban el
  corte con `maxAlternatives`, que ya no es la perilla que lo hace: pasan a `maxCandidates`. El
  comportamiento probado —que hay un tope y que conserva la llegada más temprana— no cambia.

- [x] **2/2 — El criterio en el estado del mapa y en la hoja**
  `VigoCore/Sources/VigoCore/MapFlow/MapNavigationState.swift`;
  `App/ILoveVigoRoutes/Views/Map/MapScreenModel.swift`, `Map/MapRouteSheet.swift`,
  `Map/MapScreen.swift`; tests en `MapNavigationStateTests.swift` (+5, suite
  `MapOrderingTests`).

  `visibleJourneys` aplica el criterio y corta a lo que cabe. El corte vive aquí y no en el
  motor a propósito: el planificador devuelve un conjunto mayor que la pantalla justo para que
  la preferencia elija de él.

  `setOrdering` vuelve a la primera alternativa y apaga el seguimiento. `selectedAlternative` es
  un índice sobre la lista **visible**, así que reordenar sin resetearlo deja el mapa resaltando
  una ruta y la lista otra — el mismo argumento que ya estaba escrito en `selectAlternative(at:)`.

  En la app: menú en la cabecera de «Alternativas» (no `Picker` segmentado, por lo ya
  argumentado para la hora de salida), preferencia en `UserDefaults` bajo `route.ordering` —la
  misma línea que este proyecto ya traza: presentación trivial a `UserDefaults`, datos del
  usuario a SQLite—, y las trazas se reconstruyen al cambiar de criterio **sin replanificar**.
  Una clave sin escribir, o con un criterio que una versión posterior quite, cae al valor por
  defecto.

  De paso, el tiempo real se pide solo para las visibles y no para el conjunto entero:
  preguntar por trayectos que nadie mira sería justo el sondeo que el §8 del handoff descarta.

**Fase 10 completa — 2 pasos.** Suite de `VigoCore`: **311 tests en verde** (+20). Target de app:
**16 tests en verde**. Debug y Release compilan.

**Medido contra el feed real** (archivo descargado el 2026-09-05, 17,2 MB): planificación en
frío —construcción del `Timetable` incluida— en **122,9 ms**, con el presupuesto del handoff en
1 s. Generar hasta tres bajadas por ronda y un frente de cuatro ejes **no ha movido el coste**:
la Fase 3 medía 129 ms sobre este mismo caso. Reconstruir es aritmética sobre arrays en memoria;
lo caro sigue siendo leer `shapePoint`, y eso sigue haciéndose solo para las visibles.

**Pendiente de comprobar en dispositivo** (lo hace el propietario):

- [x] Un destino con dos paradas de bajada plausibles: «Menos caminata» ofrece de verdad otra
      opción, no la misma reordenada
- [x] El menú de tres opciones cabe en la cabecera sin partir la fila
- [x] Cambiar de criterio con una alternativa resaltada: el mapa redibuja la correcta
- [x] El criterio elegido sobrevive a matar y relanzar la app
- [x] Con «Llega antes» la app se comporta como antes de esta fase

**Verificado en dispositivo por el propietario el 2026-09-06. Fase 10 cerrada del todo.**

## Fase 11 — Trayecto activo persistente

Plan en `PLAN-FASES-8-13.md`, §Fase 11. Rama `fase11-trayecto-activo`.

### Hecho

- [x] **Migración `v3`: `activeJourney` y `recentSearch` a la vez.**
  `VigoCore/Sources/VigoCore/Persistence/AppDatabase.swift`. Las dos tablas del plan, tal
  como pide §11.2: `recentSearch` queda creada y vacía hasta la Fase 12, para no encadenar
  una `v4` dos semanas después. Sin FK a `stop` en ninguna de las dos, por el mismo motivo
  que ya documenta la migración `v2`.

- [x] **`ActiveJourneySnapshot` + `ActiveJourneyRecord`, nuevos en `VigoCore/ActiveJourney/`.**
  Instantánea autosuficiente (`Codable` propio, no `Journey` serializado): un trayecto activo
  no se replanifica nunca, así que no le afecta que `Journey`/`JourneyLeg` sigan cambiando de
  forma (la Fase 10 lo acaba de hacer). Cada parada se guarda como `stopID` opcional más
  coordenada de respaldo (`StopRef`), nunca como un `Stop` congelado — la misma regla de
  anclaje que la Fase 4 fijó para lugares guardados. `staleness(now:grace:)` es pura y se
  mide contra `scheduledArrival`, no contra `scheduledDeparture` — el mismo error plausible
  que Fase 8 ya tuvo que evitar en `hasDeparted`.
  **Desviación menor del plan:** la resolución de un `stopID` contra la tabla `stop` viva no
  vive dentro de `ActiveJourneySnapshot` (que es un tipo de datos puro, sin acceso a base de
  datos), sino que queda para quien la use — igual que `SavedPlaceRow` no resuelve su propio
  `Stop` y es `TransitRepository` quien lo hace al leer. Aquí no ha hecho falta ese paso
  extra: la coordenada de respaldo basta para dibujar y anunciar el destino, y nada en esta
  fase necesita todavía el `Stop` resuelto.
  `TransitRepository.swift` gana `// MARK: - Trayecto activo`: `activeJourney()`,
  `startActiveJourney(_:startedAt:)` (upsert sobre la clave constante `"current"`, así que
  empezar un segundo trayecto sin terminar el primero deja exactamente uno), `endActiveJourney()`
  (cubre Terminar y Cancelar, distinguidos solo en la UI), `markActiveJourneyStale()` y
  `extendActiveJourney(to:)` ("Sigo en él", mueve `scheduledArrival` y re-escribe el blob para
  que columna y payload no diverjan).
  Tests: `ActiveJourneyTests.swift` (9) — round-trip JSON con transbordo y paradas
  intermedias, clave constante impide dos filas activas, los dos bordes de `staleness`,
  `extendActiveJourney` vuelve a activo y mueve la ventana, `endActiveJourney` sin fila no
  lanza, y un trayecto sigue leyéndose con destino resoluble por coordenada tras perder su
  parada del feed. `MigrationTests.swift` ampliado (datos de `v2` sobreviven a `v3`, ambas
  tablas nuevas presentes y vacías).

- [x] **`ActiveJourneyStore`, nuevo en el target de app.**
  `App/ILoveVigoRoutes/ActiveJourneyStore.swift`, calcado de `SavedPlacesStore`:
  `@MainActor @Observable`, `reload()` re-lee y recalcula `staleness`, `start`/`end`/`extend`
  mutan y recargan. `AppEnvironment` lo expone como `activeJourney`.

- [x] **La cápsula persistente, en `RootView`, no en `MapScreen`.**
  `App/ILoveVigoRoutes/Views/ActiveJourneyBar.swift` (nuevo). Una línea con
  `.regularMaterial` en cápsula, no una tarjeta — línea, parada de bajada, hora prevista y
  chevron, o «¿Sigues en este trayecto?» con el botón «Sigo en él» cuando está `.stale`. Vive
  en `RootView` vía `.safeAreaInset(edge: .bottom)` sobre el propio `TabView`, por encima de
  la barra de pestañas y compartida por Mapa y Favoritas — `MapScreen` ya usa su propio
  `safeAreaInset` para la barra de búsqueda, pero ese está dentro de la pestaña Mapa
  únicamente. Menú contextual con Terminar/Cancelar; Cancelar pide confirmación destructiva,
  Terminar no. `RootView` recalcula `staleness` al volver a primer plano
  (`scenePhase == .active`), para que un trayecto empezado antes de que el teléfono se
  durmiera dos horas no siga leyendo `.active`.
  **Desviación del plan:** tocar la cápsula abre una hoja propia
  (`ActiveJourneyDetailSheet`, dentro del mismo fichero) con los tramos del trayecto, en vez
  de "abrir el mapa con ese trayecto en `.journeyDetail`" como decía el plan. Un trayecto
  activo es una instantánea (`ActiveJourneySnapshot`), no un `Journey` vivo que el
  planificador acaba de producir esta sesión — encajarlo en `MapNavigationState.journeyDetail`
  habría exigido enseñarle a ese modo a mostrar algo que no es una alternativa recién
  calculada, tocando una máquina de estados que la Fase 5 ya fijó con cuidado. La hoja propia
  da la misma información (tramos, línea, paradas, llegada prevista, Terminar/Cancelar) sin
  ese riesgo.

- [x] **«He subido a este bus».**
  `App/ILoveVigoRoutes/Views/Map/MapRouteSheet.swift`: `MapJourneyLegsView` gana una sección
  con el botón, oculta en un trayecto solo-a-pie (no hay bus que haya salido). Al tocarlo,
  `MapScreenModel.startActiveJourney()` construye el `ActiveJourneySnapshot` a partir de
  `state.currentJourney` (construcción pura, sin tocar la base de datos — la misma separación
  que ya hay entre el flujo del mapa y `AppEnvironment.requestOnMap`), y `MapScreen` se lo
  pasa a `environment.activeJourney.start(_:)`.
  **Iniciar un trayecto no enciende `isFollowing`**, tal como pide §11.5: son botones
  distintos, con costes distintos, y no se tocan entre sí.

Suite de `VigoCore`: **321 tests en verde** (+10). Target de app: **16 tests en verde**
(sin cambios — la Fase 11 no tenía test nuevo de app pendiente de escribir; los del store se
cubren indirectamente por los de `TransitRepository`). Debug y Release compilan contra
`generic/platform=iOS`.

**Deliberadamente fuera de esta fase, documentado para que no se lea como olvido:**

- `recentSearch` queda creada y sin usar — es la Fase 12.
- Ningún aviso de proximidad al destino — es la Fase 13, y depende de esta.
- El manejador de notificaciones que la Fase 13 necesitará para leer `intermediate` y decidir
  «la parada anterior» no existe todavía; el campo ya está en el `Codable` para cuando llegue.

**Pendiente de comprobar en dispositivo** (lo hace el propietario):

- [ ] La cápsula aparece al tocar «He subido a este bus» y sigue visible al cambiar de
      pestaña (Mapa ↔ Favoritas)
- [ ] Tocar la cápsula abre la hoja de detalle con los tramos correctos
- [ ] Terminar y Cancelar (con su confirmación) borran la cápsula
- [ ] Un trayecto activo sobrevive a matar y relanzar la app
- [ ] Pasados los 90 minutos de gracia tras la llegada prevista, la cápsula cambia a
      «¿Sigues en este trayecto?» y «Sigo en él» la vuelve a `.active`
- [ ] Reimportar el feed (o esperar al refresco semanal) no hace desaparecer la cápsula

## Auditoría del buscador — Tanda A: calidad del emparejamiento

`AUDITORIA-BUSCADOR.md` (2026-09-06) auditó el motor de búsquedas entero y encontró que el
emparejamiento de paradas fallaba en casos razonables — verificado contra el feed real, no
solo razonado. Esta tanda es la primera de las cuatro que el informe propone: los hallazgos
H-01 a H-06, H-09 y H-10, todos en `VigoCore` y sin tocar la app.

**H-10 — la puntuación no se plegaba.** `TextNormalization.searchFolded` quitaba acentos y
mayúsculas pero dejaba puntos, guiones y comillas, así que "avda florida" no encontraba
"Avda. da Florida". Ahora todo carácter que no sea letra o dígito se pliega a espacio antes
de colapsar los espacios. Los dígitos se conservan a propósito: un número de portal es parte
de lo que se busca.

**Efecto secundario que hay que saber: cambia `searchName`.** Esa columna se calcula en el
import (`GTFSParser.swift`, al construir cada `Stop`), así que la base ya en disco de un
dispositivo real sigue teniendo los valores plegados a la manera antigua hasta el próximo
refresco del feed — semanal, o manual desde Ajustes. No hace falta una migración `v4`: el
importador borra y reescribe la tabla `stop` entera en cada refresco (la invariante de
siempre), así que el primer refresco después de esta build autocorrige el valor sin que haga
falta ningún paso especial. Mientras tanto, la búsqueda sigue funcionando con las reglas
viejas para los nombres con puntuación — no rompe nada, solo tarda un refresco en mejorar.

**H-01 — comodines de `LIKE` sin escapar.** `TextNormalization.likePattern(_:)`, nueva,
escapa `\`, `%` y `_` para usar con `LIKE ... ESCAPE '\'`. En la práctica H-10 ya deja fuera
`%` y `_` antes de que lleguen aquí (se pliegan a espacio como cualquier otra puntuación), así
que el escapado es sobre todo defensa en profundidad para quien construya un patrón a partir
de texto que no haya pasado por `searchFolded` — y es la función que en teoría usará el
`dedupKey` de la Fase 12.

**H-09 — la consulta ya no es una única subcadena.** `searchStops` divide la consulta en
términos y exige que todos aparezcan en alguna parte del nombre, en cualquier orden:
"praza america" y "america praza" encuentran lo mismo que "praza de america". Dentro del
nivel "aparece en alguna parte", los resultados se puntúan por cuántos términos son prefijo
de alguna palabra del nombre (`termPrefixScore`), así que "coru" pone "Coruña ..." por delante
de un nombre que solo la contiene a media palabra. Sin FTS5 ni trigramas: sobre 1154 filas la
consulta sigue costando <1 ms (medido).

**H-02/H-03/H-04/H-06 — la rama numérica.** Reescrita entera:
- Ya no corta la búsqueda por nombre — un código exacto o por prefijo se **fusiona** con los
  resultados por nombre en vez de sustituirlos (antes, si algún código coincidía, ninguna
  parada con ese dígito en el nombre podía aparecer).
- El prefijo se construye desde la forma canónica (`digits` sin ceros a la izquierda), así
  que "0693" encuentra la misma parada que "693".
- El recorte a `limit` ocurre una sola vez, al final, sobre el conjunto ya fusionado —
  `exact + prefix` ya no podía superar el límite por su cuenta.
- La consulta de prefijo no depende de `Int(digits)`: una consulta de veinte dígitos ya no
  se salta la rama entera, solo no encuentra nada (correcto).

**H-05 — espacios interiores, documentado.** "69 30" sigue leyéndose como "6930" a propósito
(números leídos en voz alta o tecleados con espacios), y ahora el comentario lo dice.

**Verificación.** Suite de `VigoCore`: **335 tests en verde** (+14: 4 en
`TextNormalizationTests.swift`, nuevo; 5 en `RepositoryTests.swift`, sobre el fixture
compartido; 5 en `SearchQualityTests.swift`, nuevo, con un fixture propio y pequeño —
deliberadamente no se tocó el fixture compartido, que `GTFSParserTests`/`RepositoryTests` ya
cuentan en 4 paradas exactas). Más una batería nueva en `RealFeedIntegrationTests.swift`
(`searchQualityBattery`, tras `VIGO_GTFS_ZIP`), con los umbrales por forma que ese fichero ya
exige — nunca una cuenta exacta, porque el feed se regenera cada semana.

**Verificado por mutación, ocho veces**, cada una tumbando exactamente el test que le
corresponde: quitar el escapado de `likePattern` (H-01), quitar el plegado de puntuación
(H-10, tumba 3 tests — incluido el de `GTFSParserTests` que ya existía), volver a un único
`LIKE` sin dividir en términos (H-09, tumba dos tests, uno por fixture), usar `digits` sin
canonizar (H-03), quitar el recorte final a `limit` (H-02, tumba dos tests, uno por fixture),
volver al `return` temprano de la rama numérica (H-04), fusionar los dos niveles de
relevancia en un único orden alfabético (H-40 — y la primera versión de este test no lo
habría detectado: los dos nombres elegidos también quedaban en el orden correcto
alfabéticamente por casualidad; se corrigió con nombres adversos al alfabeto antes de
confiar en él), y quitar el filtro exacto de radio de `nearbyStops` (H-43, ya señalado por la
propia auditoría como sin cubrir).

**Deliberadamente en esta tanda y no en otra:** H-40, H-42 y H-43 son hallazgos de
testabilidad del informe (tests que faltaban, no comportamiento que faltara arreglar) que se
resolvieron aquí porque tocan exactamente el código que esta tanda ya estaba reescribiendo
— separarlos en su propia tanda habría sido reabrir el mismo fichero dos veces.

Pendiente: Tandas B (UI honesta y la ruta accesible de "Elegir en el mapa"), C (direcciones —
`MapKitAddressSearchService`) y D (deuda del buscador y desbloqueo de la Fase 12), en
`AUDITORIA-BUSCADOR.md` §6.
