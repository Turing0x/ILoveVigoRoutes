# Encargo: auditoría profunda del motor de búsquedas

> Prompt para Claude Code (Opus 5). Pégalo entero como primer mensaje en una sesión abierta
> en la raíz del repo. Está escrito para ser autosuficiente: no hace falta contexto previo.

---

Eres un auditor de código especializado en iOS/Swift 6, SQLite y motores de búsqueda con
autocompletado. Vas a auditar **una sola cosa** de este proyecto: el **motor de búsquedas**
(el buscador de la app). Esta tarea implica razonamiento en varios pasos — lee, contrasta y
piensa con cuidado antes de escribir el informe.

**No modifiques ningún fichero de código.** El entregable es un informe. Puedes ejecutar
`swift build` y `swift test` dentro de `VigoCore/` para verificar hipótesis, y puedes
escribir tests desechables en un fichero temporal fuera del repo si te ayudan a confirmar un
comportamiento, pero no toques el código fuente ni los tests existentes.

---

## 1. Qué es este proyecto

App iOS nativa en SwiftUI para el transporte público de Vigo (autobuses de Vitrasa). Proyecto
personal, sin distribución, sin cuentas, sin telemetría. iOS 18 mínimo, Swift 6 con
`SWIFT_STRICT_CONCURRENCY: complete`, `swiftLanguageMode(.v6)` en el paquete.

Dos targets:

- **`VigoCore/`** — paquete SwiftPM, sin UIKit ni MapKit, con toda la lógica y toda la
  persistencia (GRDB 7 sobre SQLite). Tiene ~280 tests y es donde vive lo que se puede
  verificar sin simulador. Es el sitio donde el proyecto quiere que viva la lógica.
- **`App/ILoveVigoRoutes/`** — la app SwiftUI. Sus tests (`App/ILoveVigoRoutesTests/`) son
  pocos (16) porque el target necesita simulador.

Datos: un GTFS de Vitrasa importado semanalmente (1.149 paradas, 59 rutas de las que 43
tienen servicio real, ~63k `stop_times`). El importador **borra y reescribe la tabla `stop`
entera en cada refresco** — eso es una invariante que atraviesa todo el diseño: nada
persistido puede guardar un `Stop` serializado, solo `stopID` + coordenada de respaldo.

Documentación viva que debes leer antes de empezar, en este orden:

1. `README.md` — decisiones sobre el feed.
2. `ESTADO.md` — estado por fases. Lee especialmente **la sección «Fase 7 — Un solo
   buscador, dos pestañas»**, que es la historia del motor que vas a auditar.
3. `PLAN-FASES-8-13.md` — **§12 completa** (Fase 12, «búsquedas recientes»), que es trabajo
   planificado y aún no hecho sobre este mismo motor.
4. `DATA-SOURCES.md` §3.6 — normalización de nombres de línea entre el feed y la API de
   tiempo real.

El proyecto documenta sus decisiones **dentro del código**, en comentarios largos que
explican el *porqué*. Trátalos como parte del artefacto que auditas: un comentario que ya no
describe lo que hace el código es un hallazgo, y un comentario que declara una invariante te
da el criterio con el que juzgar si el código la cumple.

## 2. Qué es «el motor de búsquedas»

Todo lo que ocurre desde que el usuario toca la barra de búsqueda del mapa hasta que un
resultado se convierte en un `MapPlace` entregado al llamador. Cinco fuentes de resultados
conviviendo en una sola hoja: **paradas** (SQLite), **direcciones y POIs** (Apple/MapKit),
**líneas**, **lugares y trayectos guardados**, **favoritas**, más **«Cerca de ti»**, **«Mi
ubicación»** y **«Elegir en el mapa»**.

**Fuera de alcance, no lo audites:** el planificador RAPTOR (`Planner/`), el tiempo real
(`Network/`, `ArrivalsService`), el importador GTFS salvo el punto exacto donde calcula
`searchName`, el dibujo del mapa, Favoritas, el trayecto activo, y la Fase 13. Si tropiezas
con algo grave fuera de alcance, anótalo en una sección aparte de dos líneas y sigue.

### 2.1 Inventario de ficheros (audítalos todos, no solo los que menciono como ejemplo)

**Núcleo, en `VigoCore/Sources/VigoCore/`:**

| Fichero | Qué mirar |
|---|---|
| `GTFS/TextNormalization.swift` | `searchFolded` — la función de plegado que decide qué matchea con qué. Es el corazón semántico del buscador |
| `GTFS/GTFSParser.swift` (~línea 137) | Dónde y cómo se calcula `searchName` en el import |
| `Persistence/TransitRepository.swift` | `searchStops(_:limit:)` (~193-219), `nearbyStops(...)` (~161-186), `routesWithService()` (~254), `routeShortNames(_:stopID:)` (~228), `lineNameOrdering` (~240), `haversineMetres` |
| `Persistence/AppDatabase.swift` | Índices `stop_searchName`, `stop_vitrasaCode`, `stop_lat_lon`; tabla `recentSearch` creada en `v3` y **hoy sin usar** |
| `MapFlow/MapPlace.swift` | `MapPlace`, `Origin`, `symbolName`, `savedEndpointInput`, `savedEndpoint` |
| `Model/DomainModels.swift` | `Stop`, `Route`, `Place`; y `NearbyStop` (en `TransitRepository.swift`) |

**App, en `App/ILoveVigoRoutes/`:**

| Fichero | Qué mirar |
|---|---|
| `Views/Map/MapSearchSheet.swift` | **El fichero central.** La hoja entera, `Purpose`, `matchingLines`, `pick(_:)`, secciones del estado vacío y de resultados, `MapBrowseBar` |
| `AddressSearch.swift` | `AddressSuggestion`, `AddressSearchError`, el protocolo `AddressSearching`, `VigoSearchRegion` |
| `AddressSearchModel.swift` | Debounce, cancelación, estados `isSearching`/`failed`/`resolving` |
| `MapKitAddressSearchService.swift` | Completer, continuación pendiente, tabla `completions`, `resolve`. El propio fichero declara que es «el código de más riesgo de la funcionalidad y no está cubierto por tests» |
| `Views/Map/MapPlaceResolver.swift` | Geocodificación inversa del pin |
| `Views/MapPointPickerView.swift` | «Elegir en el mapa» |
| `LocationProvider.swift` | El segundo `CLLocationManager` que la hoja levanta encima del del mapa |
| `AppEnvironment.swift` | Cómo se construye y comparte `addressSearch` (un solo servicio para toda la vida de la app) |
| `Views/Map/MapScreen.swift`, `MapScreenModel.swift`, `PlacePickerRole.swift` | Solo la parte que presenta la hoja y consume su resultado |
| `Views/SavedPlaceEditorView.swift`, `Views/SavedJourneyEditorView.swift` | Solo como llamadores de `.standalone` / `.endpoint` |

**Tests existentes que cubren este motor:**
`App/ILoveVigoRoutesTests/AddressSearchModelTests.swift`, `StubAddressSearchService.swift`;
`VigoCore/Tests/VigoCoreTests/RepositoryTests.swift` (los casos `searchByName`,
`searchByNumber`, `nearby`, `nearbyRadius`); `MigrationTests.swift` (la tabla `recentSearch`).

## 3. Invariantes que el proyecto se ha impuesto

Úsalas como criterio. Una violación es un hallazgo aunque el código «funcione».

1. **La ubicación del usuario no sale del dispositivo.** `NSLocationWhenInUseUsageDescription`
   lo promete. Por eso la búsqueda de direcciones está fijada a una caja de Vigo constante
   (`VigoSearchRegion`) en vez de sesgarse a la posición real, y por eso la geocodificación
   inversa solo se hace sobre un punto que el usuario ha pulsado a propósito. Verifica que
   **ningún** camino del buscador filtra la posición a Apple, incluidos los indirectos.
2. **Ser buen ciudadano con las fuentes.** Una `MKLocalSearch` completa solo al tocar un
   resultado, nunca por pulsación de tecla. Cuenta cuántas llamadas a Apple genera de verdad
   cada flujo, incluida la acción de deslizar «Guardar».
3. **Nada guarda un `Stop` serializado.** El import reescribe la tabla; todo se ancla por
   `stopID` + coordenada de respaldo (`SavedPlaceAnchor`).
4. **Un solo buscador.** La Fase 7 existe porque había dos que ya divergían. Cualquier
   lógica de búsqueda duplicada hoy es exactamente la deuda que esa fase pagó.
5. **Un solo embudo.** Los seis sitios que producen un resultado pasan por `pick(_:)`. La
   Fase 12 depende de que eso siga siendo cierto.
6. **La lógica verificable vive en `VigoCore`.** Lo que está en una `View` no se puede
   testear sin simulador. Si encuentras lógica de decisión atrapada en `MapSearchSheet`,
   di cuál y a qué tipo de `VigoCore` debería mudarse.
7. **Swift 6 estricto.** Nada de `@unchecked Sendable` ni `assumeIsolated` sin una
   justificación escrita que resista.

## 4. Ejes de la auditoría — cúbrelos todos, para todos los ficheros del inventario

No te limites al primero ni a los que te resulten más evidentes. Recorre los nueve ejes
completos contra **cada** fichero del §2.1 en el que apliquen.

**A. Corrección de la consulta de paradas.** Semántica de `LIKE` en SQLite: comodines en la
entrada del usuario, `ESCAPE`, colación, sensibilidad a mayúsculas con y sin ASCII. Interacción
entre el plegado de Swift (`folding` con `es_ES`) y la comparación de SQLite. La rama numérica:
qué es «numérico», qué pasa con espacios, con ceros a la izquierda, con desbordamiento de `Int`,
y si `exact + prefix` puede superar `limit`. El orden de los resultados y si la mezcla
prefijo/contenido puede descartar el resultado bueno.

**B. Calidad del emparejamiento y relevancia.** Qué consultas razonables **fallan** hoy.
Construye una batería con nombres reales del feed y compruébala: puntuación en el nombre
(`Av.`, `Ctra.`), apóstrofes y guiones, palabras en otro orden, dos términos no contiguos,
errores tipográficos de una letra, topónimos gallegos y sus variantes castellanas, «ñ», stop
words (`de`, `da`, `do`). Di cuáles fallan, por qué, y qué las arreglaría — incluida la
pregunta de si FTS5 o un índice de trigramas se justifica sobre 1.149 filas, o si es
sobreingeniería y basta con normalizar mejor.

**C. Concurrencia y ciclo de vida.** El invariante «como mucho una continuación pendiente,
resumida exactamente una vez» de `MapKitAddressSearchService`: intenta romperlo. Resultados
que llegan tarde y se atribuyen a la consulta equivocada. Refinamientos del completer que
llegan después de haber resumido. Qué pasa con la tabla `completions` cuando la lista visible
ya no corresponde a lo que tiene el servicio. Tareas que sobreviven a la hoja. Estados que se
quedan pegados (`isSearching`, `resolving`, `failed`). Dos resoluciones simultáneas (toque y
deslizar). Ausencia de timeout. Qué ocurre si MapKit nunca contesta.

**D. Rendimiento y coste.** Cada tecleo: qué trabajo hace, en qué actor, cuántas veces se
reevalúa el `body`, cuántas consultas a SQLite, cuántas asignaciones de memoria. Consultas
N+1. Si los índices declarados se usan de verdad — compruébalo con `EXPLAIN QUERY PLAN`
contra una base real, no por inspección. Coste del `Task.detached` de líneas y del
`.task(id:)` de cercanía, y si el redondeo de coordenada a ~11 m es el umbral correcto para
alguien caminando. Dos `CLLocationManager` vivos a la vez.

**E. Comportamiento de la UI.** Estados en los que la hoja miente: el vacío que aparece antes
de haber buscado, la condición del texto de ayuda del estado vacío, secciones que se muestran
o esconden por criterios que no coinciden entre sí. Dos modificadores `.sheet` sobre la misma
vista. Filas que no se pueden tocar. Qué pasa si el usuario teclea antes de que `.task`
termine de construir el modelo de direcciones. Reentrada al presentar y descartar la hoja.

**F. Errores y casos límite.** Sin red, MapKit throttleado, base sin importar (`hasData ==
false`), feed caducado, permiso de ubicación denegado o restringido, coordenada `nil`,
resultado justo en el borde de `VigoSearchRegion` (¿coinciden la caja que pide MapKit y la que
comprueba `contains`?), consulta de un solo carácter, consulta de 500 caracteres, emoji, RTL,
pegar texto con saltos de línea.

**G. Accesibilidad.** VoiceOver sobre `Button` con `.buttonStyle(.plain)` dentro de `List`,
etiquetas y valores de las filas, acciones de deslizar accesibles, el `ScrollView` horizontal
de insignias de línea dentro de una fila, Dynamic Type en las filas de dos líneas con
distancia a la derecha, contraste. La Fase 7 cerró un hueco de accesibilidad a propósito
(«Elegir en el mapa» como ruta accesible a soltar un pin): comprueba que sigue cerrado.

**H. Testabilidad y cobertura.** Qué del motor es hoy inverificable sin simulador y por qué.
Para cada hueco, propón el corte concreto: qué tipo puro extraer, a qué fichero de `VigoCore`,
con qué firma. Interesa especialmente si el mapeo «consulta → secciones y su orden» puede
convertirse en una función pura testeable. Y verifica los tests que **sí** existen: ¿pasarían
igual con el código roto? Prueba mutaciones deliberadas — es el método que este proyecto ya
usa y documenta en `ESTADO.md` (Fase 3, paso 3/11).

**I. Preparación para la Fase 12.** La tabla `recentSearch` ya está creada y vacía. Contrasta
el esquema y el diseño de `dedupKey` de `PLAN-FASES-8-13.md` §12.3 contra los seis casos de
`MapPlace.Origin` y contra el embudo `pick(_:)` tal y como está hoy. ¿El plan sobrevive al
código real, o hay algo en el buscador actual que habrá que cambiar antes? Dilo ahora, que es
barato.

## 5. Reglas del informe

**Cobertura, no precisión.** Reporta **cada** problema que encuentres, incluidos los que no
tengas claros y los que consideres de baja severidad. No filtres por importancia ni por
confianza en esta etapa. Si dudas entre reportar y callar, reporta. Un hallazgo menor con la
etiqueta «confianza baja» vale más que un hallazgo omitido.

Para **cada** hallazgo, en este formato:

```
### H-nn · <título de una línea>
**Fichero:línea** · **Severidad:** crítica | alta | media | baja | nit ·
**Confianza:** alta | media | baja · **Categoría:** bug | corrección | rendimiento |
concurrencia | UX | accesibilidad | testabilidad | invariante | deuda

**Qué pasa.** El comportamiento observable, no la abstracción.
**Cómo reproducirlo.** Entrada concreta y resultado esperado frente al real.
**Por qué pasa.** La causa en el código, citando las líneas.
**Cómo lo arreglaría.** El cambio mínimo, con el código si cabe en pocas líneas.
**Cómo lo verificaría.** El test concreto — nombre, fichero donde iría, y qué mutación del
código de producción debería tumbarlo.
```

Cuando afirmes algo sobre el comportamiento de SQLite, de MapKit o del runtime de Swift,
**verifícalo** antes de escribirlo: ejecuta la consulta, escribe el test, lee la
documentación. Si no puedes verificarlo (todo lo que necesita simulador o los servidores de
Apple), márcalo explícitamente como **«no verificado — razonamiento»** y baja la confianza.
No presentes una deducción como una observación.

Estructura final del informe:

1. **Resumen ejecutivo** — 10 líneas como máximo: en qué estado está el motor y las tres
   cosas que arreglarías primero.
2. **Tabla de hallazgos** — todos, ordenados por severidad y luego por fichero.
3. **Hallazgos en detalle** — con el formato de arriba.
4. **Mapa del motor** — el recorrido real de una pulsación de tecla hasta un `MapPlace`,
   incluyendo cada salto de actor, cada consulta y cada llamada de red. Escríbelo aunque no
   encuentres nada mal en él: es la mitad del valor de esta auditoría.
5. **Lo que está bien** — decisiones que aguantan el escrutinio y que un refactor futuro no
   debería deshacer sin entenderlas. Sé específico; no es una sección de cortesía.
6. **Plan sugerido** — los hallazgos agrupados en tandas coherentes, cada una con lo que
   habría que verificar para darla por buena. Ordenadas por valor entregado, no por severidad.

Escribe el informe en **castellano**, en `AUDITORIA-BUSCADOR.md`, en la raíz del repo. Es el
único fichero que puedes crear.

## 6. Cómo empezar

1. Lee los cuatro documentos del §1 antes de abrir código.
2. Lee **todos** los ficheros del inventario del §2.1 antes de escribir un solo hallazgo. El
   motor está repartido entre el paquete y la app a propósito, y un juicio sobre
   `MapSearchSheet` sin haber leído `TransitRepository` será equivocado.
3. Ejecuta `swift test` en `VigoCore/` para partir de una suite verde y saber cuánto tarda.
4. Construye una base de datos con el feed real (mira `RealFeedIntegrationTests.swift` para
   ver cómo lo hacen los tests) y **ejecuta consultas de verdad** contra ella: la batería del
   eje B y los `EXPLAIN QUERY PLAN` del eje D no son opcionales.
5. Recorre los nueve ejes del §4 fichero por fichero.
6. Escribe el informe.
