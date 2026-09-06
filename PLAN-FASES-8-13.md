# PLAN-FASES-8-13.md — Caminatas, actualizar a mano, horarios, ordenación, trayecto activo, recientes y avisos

Plan de implementación. **Nada de esto está escrito todavía**: este documento es la decisión
previa, no el registro de lo hecho. El avance se anota en `ESTADO.md` paso a paso, como en todas
las fases anteriores.

Las fases siguen la numeración de `README.md` y `ESTADO.md`. El orden en que aparecen aquí es el
orden de implementación.

| Fase | Qué | Depende de |
|---|---|---|
| **8** | Las caminatas en el mapa, actualizar a mano y «ya ha salido» | Nada |
| **9** | Todos los horarios de una línea en una parada | Nada |
| **10** | Criterio de ordenación de alternativas, con caminata final por defecto | Fase 8 (ver §10.0) |
| **11** | Trayecto activo persistente (y **migración `v3` completa**) | Nada |
| **12** | Búsquedas recientes, máximo 10 | Fase 11, solo por la migración |
| **13** | Aviso de llegada al destino | Fase 11 |

**Las fases 8 y 9 son nuevas** y nacen de la prueba en dispositivo del 2026-09-05, después de
fusionar la Fase 7: tres cosas que el propietario echó en falta usando la app de verdad —el
trazado a pie no se dibuja, no hay forma de volver a preguntar cuando se escapa el autobús, y no
se pueden ver todos los horarios de una línea—. Se colocan **antes** de las cuatro ya planificadas
porque son defectos de lo ya entregado, no funcionalidad nueva, y porque la Fase 10 depende de la
primera de ellas (§10.0). Las cuatro anteriores conservan su contenido íntegro y solo cambian de
número: la 8 pasa a 10, la 9 a 11, la 10 a 12 y la 11 a 13. Renumerar ahora es gratis —ninguna
está escrita ni anotada en `ESTADO.md`— y deja de serlo en cuanto la primera se implemente.

Decisiones ya confirmadas por el propietario y cerradas: permiso de ubicación «Siempre»
concedido; criterio de cercanía = caminata final con caminata total como desempate; sin
histórico de trayectos terminados; 8 candidatos, 400 m de preaviso, 250 m de radio de geovalla,
90 minutos de gracia; **tres criterios en el menú de ordenación** (P9) y
**`maxEgressCandidates = 3`** (P10).

---

# FASE 0 de todas — Git

**Hecho ya.** `fase7-absorber-pestanas` se fusionó en `main` el 2026-09-05 en avance rápido
(`66ddf55..fe6447e`), se empujó a `origin/main` y la rama local se borró. No existía rama remota
con ese nombre, así que allí no hubo nada que retirar. `main` y `origin/main` coinciden.

Nota honesta para lo que viene: aquella fusión fue **en avance rápido**, no `--no-ff` como este
documento proponía, así que la Fase 7 no tiene commit de fusión propio y
`git log --first-parent main` no la separa del resto. No se arregla reescribiendo historia ya
empujada; a partir de la Fase 8 se retoma el commit de fusión por fase.

Convención de rama del repositorio: `faseN-` en minúsculas, en castellano sin acentos, con
guiones. **Una rama por fase**, cada una saliendo de `main` ya actualizado.

Nombres propuestos, en orden de implementación:

- `fase8-caminatas-y-actualizar`
- `fase9-horarios-de-linea`
- `fase10-orden-alternativas`
- `fase11-trayecto-activo`
- `fase12-busquedas-recientes`
- `fase13-avisos-bajada`

Ciclo por fase:

```bash
cd ~/LocalProjects/MyOwnApps/ILoveVigoRoutes

# Abrir la fase desde main actualizado.
git checkout main && git pull --ff-only origin main
git checkout -b fase8-caminatas-y-actualizar

# … trabajo, con ESTADO.md anotado paso a paso …

# Cerrar: verde y limpio antes de fusionar.
git status                        # debe estar limpio
cd VigoCore && swift test && cd ..
xcodebuild -scheme ILoveVigoRoutes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

git checkout main
git merge --no-ff fase8-caminatas-y-actualizar \
  -m "Fase 8: las caminatas en el mapa y actualizar a mano"
git push origin main
git branch -d fase8-caminatas-y-actualizar
```

`--no-ff` a propósito: `ESTADO.md` documenta las fases como unidades, y un commit de fusión por
fase hace que `git log --first-parent main` se lea como la lista de fases. Las fases 9 a 13
repiten el mismo ciclo con su propio mensaje.

---

# FASE 8 — Las caminatas en el mapa, actualizar a mano y «ya ha salido»

Tres defectos de lo ya entregado, encontrados usando la app. Ninguno necesita migración, permisos
ni motor: es la fase más barata del documento y arregla lo que más se nota.

## 8.1 Lo que de verdad pasa hoy, comprobado en el código

**Las caminatas sí salen en la lista de tramos, y no salen en el mapa.** Conviene separarlo,
porque la queja («no muestra los trayectos de caminata») admite las dos lecturas y solo una es
cierta:

- `JourneyLegRow` (`Views/JourneyRows.swift:83`) dibuja el caso `.walk` con su icono, «Caminar
  hasta X», los metros y los minutos. Y `JourneyAlternativeRow` pone un chip `figure.walk` por
  cada tramo a pie. **Eso funciona y no se toca.**
- `JourneyTraceBuilder.traces` (`Views/JourneyTrace.swift:19`) recorre los tramos y hace
  `guard case .ride(…) else { continue }`. **Un tramo a pie no produce geometría ninguna.** El
  mapa dibuja el trazado del autobús flotando, sin nada que lo una al pin de origen ni al de
  destino.
- El caso peor es `walkOnly`: un trayecto que es **solo** caminata no tiene ningún tramo `.ride`,
  así que genera cero trazas y el mapa no dibuja **absolutamente nada** — dos marcadores y un
  hueco entre ellos. Ahí la app contesta bien en la lista y parece rota en el mapa.

## 8.2 Dibujar las caminatas: línea recta discontinua, y por qué no direcciones reales

`JourneyTrace` gana una clase (`.ride` / `.walk`). Un tramo a pie aporta la recta entre sus dos
extremos, con `StrokeStyle(dash:)`.

**Descartado: `MKDirections` con `transportType = .walking`.** Daría la acera de verdad, y cuesta
lo siguiente: una petición de red **por tramo a pie y por alternativa** —hasta ocho con cuatro
alternativas—, limitada por Apple, y con las coordenadas de origen y destino saliendo del
dispositivo en cada replanificación. Este proyecto solo geocodifica cuando el usuario ha pulsado
un sitio a propósito (`MapKitPlaceResolver`, Fase 5 paso 4) y lo dice en `DataSourcesView`;
convertir eso en tráfico automático de fondo por un adorno no paga.

**Y la recta no es una aproximación vergonzante: es lo que la app ya afirma.** `JourneyLegRow`
escribe literalmente «en línea recta», `NearbyStop.distanceMetres` está documentado como
distancia recta, y `WalkModel` convierte metros a segundos con un factor. El trazado discontinuo
**dice en el dibujo lo mismo que el texto ya dice en palabras**. Una línea continua sobre la
acera equivocada sería la mentira; la discontinua no promete una ruta.

Decisiones de dibujo, con su motivo:

- **Solo la alternativa destacada dibuja sus caminatas.** Es la misma regla que ya rige los
  marcadores de parada («con cuatro alternativas compartiendo corredor, pintar todo convierte el
  centro de Vigo en confeti», Fase 5 paso 5). Las no destacadas siguen siendo su línea gris de bus.
- **Discontinua y del mismo índigo**, no un color nuevo: es el mismo trayecto, no otra cosa.
- Un tramo a pie de **cero metros** —el origen *es* la parada— no dibuja nada. Un punto no es una
  línea, y una raya de un píxel bajo el pin es ruido.

**La parte pura sube a `VigoCore`.** `Journey.walkSegments` devuelve los pares de coordenadas de
los tramos a pie, en orden, saltándose los de longitud cero; se prueba con `swift test` en el Mac.
`JourneyTraceBuilder` se queda en el target de app solo con lo que necesita SQLite y MapKit —leer
`shapePoint` y construir `CLLocationCoordinate2D`—, que es exactamente la costura que la Fase 5
dejó escrita.

## 8.3 Actualizar a mano

Hoy la respuesta es una foto del instante en que se planificó, y **los únicos disparadores de
replanificación son editar un extremo, intercambiarlos o cambiar la hora de salida**
(`MapScreenModel.setOrigin/setDestination/swapEnds/setDeparture`). Si se escapa el autobús, no hay
gesto que pregunte otra vez.

- **`.refreshable` en la `List` de `MapRouteSheet`**, más un botón explícito en la barra de
  navegación de la hoja. Los dos, no uno: tirar hacia abajo es invisible y esta hoja se abre en un
  detente donde no siempre hay recorrido para el gesto. El botón va en la barra y **no** en la
  cabecera de «Alternativas», porque la Fase 10 mete ahí el menú de ordenación y dos controles en
  una cabecera de hoja no caben en un iPhone pequeño.
- **La edad de la respuesta, a la vista.** El pie de la sección de resultados dice «Calculado a
  las 15:32». Solo con `departure == .now`: con una hora fija, la respuesta no envejece y decir
  que sí sería ruido.
- **Nada se replanifica solo.** Un recálculo automático movería la lista bajo el dedo y podría
  cambiar la alternativa destacada mientras se está leyendo. Se dice la edad y se ofrece el gesto;
  decidir es del usuario.
- **«Ya ha salido».** Cuando el primer embarque de una alternativa ya ha pasado, su fila lo dice y
  se atenúa. Esto es lo que contesta directamente a «si se me va el bus»: el estado se ve **antes**
  de tocar nada, en vez de descubrirlo en la parada.
- **El trazado no parpadea.** `MapScreenModel.plan()` hace `traces = []` antes de planificar; en
  una actualización manual eso borra del mapa la ruta que se está mirando durante toda la
  consulta. Las trazas viejas se conservan hasta que llega el resultado nuevo, y solo se tiran si
  falla.
- **El tiempo real no se fuerza.** `ThrottledRealtimeProvider` impone 20 s y **eso no se toca**:
  los endpoints no tienen API oficial y el §8 del handoff lo convierte en obligación. Una
  actualización dentro de esa ventana recibe la caché, y el botón no promete lo contrario.

**La parte pura sube a `VigoCore`**, junto a `FirstBoardingMatch`, que ya sabe encontrar el primer
tramo en bus: `hasDeparted(_ journey:, now:)`. **Se compara contra el embarque, no contra
`Journey.departure`** — `departure` es el momento de empezar a andar hacia la parada, no la hora
del autobús. Es la misma distinción que §10.1 tiene que hacer para `earliestBoarding`, y el mismo
error plausible.

## 8.4 Cambios por fichero

| Fichero | Cambio |
|---|---|
| `VigoCore/Planner/Journey.swift` | `walkSegments: [(Coordinate, Coordinate)]`, saltando los de longitud cero |
| `VigoCore/Planner/FirstBoardingMatch.swift` | `hasDeparted(_:now:)`, sobre el primer tramo en bus |
| `App/Views/JourneyTrace.swift` | `JourneyTrace.kind` (`.ride` / `.walk`); `traces(for:)` añade las rectas a pie; `JourneyMapContent` las pinta discontinuas |
| `App/Views/Map/JourneyOverviewMapContent.swift` | Solo la destacada dibuja caminatas |
| `App/Views/Map/MapScreenModel.swift` | `refresh()`; `plannedAt: Date?`; `plan()` conserva las trazas hasta tener resultado |
| `App/Views/Map/MapRouteSheet.swift` | `.refreshable`, botón en la barra, pie con la hora de cálculo, fila atenuada con «Ya ha salido» |
| `App/Views/JourneyRows.swift` | `JourneyAlternativeRow` acepta `hasDeparted` y lo dice |

## 8.5 Pruebas y mutaciones

| Test | Mutación deliberada que debe tumbarlo |
|---|---|
| Un trayecto `walkOnly` produce **un** segmento a pie | Conservar el `continue` para los tramos que no son `.ride`: hoy `walkOnly` no dibuja nada, y es el caso peor del defecto |
| Un trayecto con acceso, bus y salida produce **dos** segmentos a pie, en ese orden y con las coordenadas correctas | Invertir `from` y `to`: la recta se dibuja igual y va al revés, invisible salvo con transbordo |
| Un tramo a pie de cero metros **no** produce segmento | Emitirlo igual: una raya de un píxel bajo el pin |
| `hasDeparted` es cierto un segundo después del **embarque**, no de `Journey.departure` | Comparar contra `journey.departure`. Falla solo cuando la caminata de acceso no es cero — construir el caso a propósito |
| `hasDeparted` de un trayecto `walkOnly` es falso siempre | Devolver cierto por no haber embarque: un trayecto a pie no se escapa |

**No automatizable:** que la línea discontinua se distinga de la continua a la escala a la que
abre el mapa; que el botón de actualizar no quede debajo del pulgar del gesto de arrastrar la
hoja. Comprobación en dispositivo.

---

# FASE 9 — Todos los horarios de una línea en una parada

La otra mitad de «¿y el siguiente?». La Fase 8 vuelve a preguntar por ti; esta enseña la tabla
entera para que no haga falta preguntar.

El caso que lo motiva, tal cual: Reiseñor 12 → Alcampo devuelve C3D, 15A, 4C y **otra vez C3D**.
Dos alternativas de la misma línea a horas distintas es exactamente lo que una tabla de horarios
colapsa en una sola lista legible.

## 9.1 Qué se enseña y desde dónde se llega

**Desde el tramo en bus del detalle** (`MapJourneyLegsView` → `JourneyLegRow` en su caso
`.ride`): tocarlo empuja «Horarios de la línea 15A en \<parada de subida\>». Es donde el
propietario lo pidió y donde la pregunta nace.

**Alcance: una línea, una parada, un día de servicio.** No la tabla completa de la línea en todas
sus paradas — eso es un horario impreso, no una respuesta. Lo que resuelve la duda real («¿cuándo
pasa el siguiente por *aquí*?») es la columna de esta parada.

Contenido de la pantalla:

- **Selector de día**, acotado a los días que el feed cubre de verdad
  (`FeedStatus.serviceWindow`, siete días). Ofrecer un día fuera de la ventana sería una lista
  vacía sin explicación; el propio selector es la explicación.
- **Una sección por sentido**, separadas por `headsign`. Una parada puede tener las dos
  direcciones, y mezclarlas en una sola columna de horas produce una tabla que no significa nada.
- **La próxima salida marcada**, y la lista abierta ya desplazada hasta ella. A las 20:00 nadie
  quiere leer desde las 06:00.
- **Arriba, el tiempo real de esa línea en esa parada** si lo hay, con su `DataKindBadge`, y el
  resto etiquetado como horario. Se reutiliza lo que ya existe (`StopArrivalsSummary`,
  `ArrivalsService`); no se añade ni una petición nueva.
- **El día de servicio dicho en voz alta**, con la advertencia de la ventana de siete días que el
  resto de la app ya da.

## 9.2 La consulta

`scheduledDepartures(stopID:from:horizon:limit:)` ya existe, pero **no sirve tal cual**: es de
todas las líneas, con horizonte de 3 h y tope de 30 filas. Hace falta una hermana:

```swift
public func scheduledDepartures(
    stopID: StopID, routeID: RouteID, on serviceDate: ServiceDate
) throws -> [ScheduledDeparture]
```

Un día entero de una línea en una parada son 60–80 filas: no necesita tope.

**El detalle que no se puede olvidar, y que el método existente ya documenta:** un viaje que sale
a las `30:31:00` pertenece al **día de servicio anterior**. Preguntar solo por el día pedido
pierde todas las salidas de madrugada de las líneas nocturnas. La consulta nueva mira los mismos
dos días de calendario, y la pertenencia de una fila al día que se está enseñando la decide su
`absoluteDate`, no la etiqueta del día de servicio del que salió.

`ScheduledDeparture` ya trae todo lo que la pantalla necesita —`routeShortName`, `headsign`,
`departure`, `serviceDate`, `absoluteDate`— y `destination` ya resuelve headsign vacío contra
`routeLongName`. No hace falta tipo nuevo.

**La parte pura sube a `VigoCore`**: `DepartureBoard.build(departures:now:)` agrupa por sentido,
ordena y señala cuál es la siguiente. Así el agrupado y el «ahora» se prueban en el Mac; la vista
solo dibuja.

## 9.3 Deliberadamente fuera de esta fase

- **«Ver todos los horarios» desde la ficha de una parada.** Encaja igual de bien y sería el
  segundo sitio natural, pero ahí no hay una línea elegida: haría falta primero un selector de
  línea de la parada (`routeShortNames(stopID:)` ya existe). Se anota como continuación obvia, no
  se mete aquí.
- **Filtrar la capa de paradas por línea.** Lo pedía implícitamente la sección «Líneas con
  servicio» de la Fase 7, que dejó sus filas no interactivas por no existir consulta
  stopID-por-routeID. Sigue sin existir y sigue fuera.

## 9.4 Cambios por fichero

| Fichero | Cambio |
|---|---|
| `VigoCore/Persistence/TransitRepository.swift` | `scheduledDepartures(stopID:routeID:on:)`, día completo, ambos días de servicio |
| `VigoCore/Departures/DepartureBoard.swift` | **Nuevo y puro.** Agrupar por sentido, ordenar, señalar la siguiente |
| `VigoCore/Persistence/FeedStatus` | `serviceDays` — los días que la ventana cubre, para el selector |
| `App/Views/LineTimetableView.swift` | **Nuevo.** La pantalla |
| `App/Views/JourneyRows.swift` | El tramo `.ride` empuja a la pantalla nueva |

## 9.5 Pruebas y mutaciones

| Test | Mutación deliberada que debe tumbarlo |
|---|---|
| Una línea con salida a las `25:10` aparece en el día correcto | Preguntar solo por el día pedido. **La mutación de esta fase**: sin ella todo parece funcionar salvo de madrugada, que es cuando importa |
| Una parada servida en los dos sentidos produce **dos** secciones | Agrupar solo por línea: una columna de horas que no significa nada |
| Con `now` entre dos salidas, «la siguiente» es la primera **posterior** | Devolver la primera de la lista: a las 20:00 señala la de las 06:00 |
| Con `now` posterior a la última salida del día, no hay siguiente y **no revienta** | Forzar un índice: el caso de la última hora es el que nadie prueba a mano |
| El selector de día no ofrece un día fuera de `serviceWindow` | Ofrecer siete días desde hoy sin mirar la ventana: el feed real de esta semana **empieza mañana** (ya pasó en la Fase 3 paso 7), así que «hoy» puede estar fuera |
| Los horarios de una línea no incluyen los de otra que para en el mismo poste | Olvidar el filtro por `routeID` |

**No automatizable:** que la lista abra desplazada a la hora correcta y que la tabla se lea de un
vistazo en un iPhone pequeño. Comprobación en dispositivo.

---

# FASE 10 — Criterio de ordenación de alternativas

## 10.0 Depende de la Fase 8

El criterio por defecto pasa a ser **la caminata final**, y hasta la Fase 8 el mapa no dibuja
ninguna caminata. Un criterio que ordena por algo que no se ve es indemostrable: el usuario
elegiría «Menos caminata» y vería exactamente el mismo dibujo. No empezar esta fase antes de que
la 8 esté cerrada.

## 10.1 Las tres nociones en juego, nombradas

El encargo original y el cambio posterior mezclan tres cosas que **no son la misma** y que pueden
dar tres órdenes distintos sobre el mismo conjunto de alternativas. Nombrarlas es la mitad del
trabajo de esta fase.

| Noción | Qué mide exactamente | De dónde sale hoy |
|---|---|---|
| **Sale antes** (`earliestBoarding`) | El instante en que el **primer autobús** pasa por la parada de embarque | `FirstBoardingMatch.firstRide(of:)?.departure` |
| **Llega antes** (`earliestArrival`) | El instante en que se llega **al destino final**, puerta a puerta, caminata final incluida | `Journey.arrival` |
| **Menos caminata** (`leastWalkAtEnd`) | Segundos del **último tramo a pie**, del punto de bajada al destino | último `JourneyLeg.walk` |

Tres precisiones que importan:

1. **`Journey.arrival` ya incluye la caminata final.** En `JourneyReconstruction.reconstruct`:
   `arrival: timetable.date(forAxisSeconds: Int(networkArrival &+ egressSeconds))`. Así que
   «llega antes» no es «el bus llega antes a su última parada», es puerta a puerta.
2. **`Journey.departure` no es «sale antes».** Es el momento de empezar a andar hacia la parada
   (`firstBoardTime − accessSeconds`), y el trayecto a la parada varía entre alternativas. Lo que
   el propietario pidió —«el que antes llega a la parada de origen»— es el **embarque**, no la
   salida de casa. Por eso `earliestBoarding` se define sobre la primera parada embarcada y no
   sobre `Journey.departure`.
3. **«Sale antes» significa esperar más, no menos.** El desempate actual de `ranked`
   (`first.departure > second.departure`) prefiere justo lo contrario: a igualdad de llegada,
   salir *más tarde*, porque es menos rato de pie en la parada. Son preferencias opuestas y ambas
   legítimas — «prefiero ir en marcha» frente a «prefiero no esperar». `earliestBoarding` es la
   primera; el desempate de hoy es la segunda. No es un error de nadie: son dos personas
   distintas el mismo día.

## 10.2 Qué se ofrece en la UI, y una recomendación que no es obedecer

Lo pedido son dos criterios: **caminata final por defecto**, y **sale antes** como alternativo.
Eso deja fuera de la UI el orden que existe hoy, «llega antes».

**Recomendación: ofrecer los tres, con «Menos caminata» por defecto.**

El argumento en contra de quitar «llega antes» es que es el único criterio que responde a la
única pregunta con consecuencias: *¿llego a tiempo?* «Menos caminata» y «sale antes» son
preferencias de comodidad; ninguno de los dos sabe nada de a qué hora estás donde tienes que
estar. El día que se sale con el tiempo justo, el orden que hace falta es el que hoy existe, y
quitarlo obliga a leer las cuatro filas y comparar horas a mano — que es exactamente lo que la
lista ordenada existe para evitar.

El coste de mantenerlo es una línea más en un `Menu` que ya va a tener dos. No hay coste de
cómputo: los tres criterios ordenan el mismo conjunto ya calculado.

**Si aun así se prefieren solo dos**, la degradación correcta es conservar «llega antes» como
**desempate interno** de los otros dos, nunca eliminarlo del todo: dos alternativas con la misma
caminata final deben resolverse por la que llega antes, no por el orden en que RAPTOR las
encontró. Eso ya está en el diseño de §10.5 en cualquiera de los dos casos.

**Decisión que queda escrita, a la espera de tu palabra final (§6, P9):** se implementan los tres
en `JourneyOrdering`, y si decides mostrar solo dos, ocultar el tercero en el `Menu` es borrar un
`case` de la lista que el menú recorre, no tocar la lógica.

## 10.3 El problema de verdad: los candidatos se generan optimizando llegada

Esto es lo más importante de la fase y **contradice en parte lo que planifiqué antes**. Al hacer
«menos caminata» el criterio **por defecto**, deja de bastar con reordenar: hay que asegurarse de
que la alternativa que menos te hace andar **llega a existir**. Hoy no está garantizado, por dos
motivos independientes.

### Motivo 1 — `bestEgress` elige una sola parada de bajada por ronda

`JourneyReconstruction.bestEgress(upTo:result:query:)` recorre todas las paradas de salida
(las que están a menos de `accessRadiusMetres` = 800 m del destino) y se queda con **una**:

```swift
let total = value &+ exit.seconds
if best == nil || total < best!.arrival { best = (r, Int(exit.stop), exit.seconds, total) }
```

Es decir, la que minimiza la llegada puerta a puerta. Una parada que te deja a 100 m del portal
pero a la que el bus llega tres minutos más tarde **nunca se reconstruye**. No es que se filtre
después: no se genera. Con «llega antes» como único criterio eso era correcto por construcción;
con «menos caminata» por defecto es un fallo silencioso — el selector cambiaría el orden de
cuatro alternativas que fueron todas elegidas por rapidez.

### Motivo 2 — el filtro de dominadas no conoce la caminata

`JourneyPlanner.ranked` descarta dominadas mirando tres ejes: salida, llegada, transbordos. La
caminata final no está. Caso concreto y perfectamente posible:

- **X**: sale 9:00, llega 9:40, 1 transbordo, **2 min a pie al final**
- **Y**: sale 9:05, llega 9:38, 0 transbordos, 15 min a pie al final

Y domina a X en los tres ejes, así que X se descarta. Bajo «menos caminata», X era la respuesta.

## 10.4 Solución: candidatos Pareto en (llegada, caminata final)

Tres cambios, todos en `VigoCore`, todos con test de mutación propio.

**a) `bestEgress` → `egressCandidates`.** En vez de una parada de bajada por ronda, el **frente de
Pareto** sobre (llegada puerta a puerta, segundos de caminata final), acotado por
`PlannerOptions.maxEgressCandidates` (propuesta: **3**). Una parada de bajada entra si ninguna
otra llega antes *y* deja más cerca. Ordenadas por llegada, se reconstruyen todas.

El frente es pequeño por naturaleza: solo entran paradas que compran cercanía a cambio de tiempo,
y en la práctica son dos o tres. El coste añadido es reconstruir 2–3 trayectos más por ronda —
reconstrucción es aritmética sobre arrays en memoria, no toca SQLite.

**b) `dominates` gana un cuarto eje.** Salida (más tarde mejor), llegada (antes mejor),
transbordos (menos mejor) y **caminata final (menos mejor)**. Sin esto, el punto (a) genera los
candidatos buenos y el punto siguiente los tira a la basura.

Consecuencia honesta y aceptada: el frente crece, porque un eje más significa menos dominancia.
Por eso `maxCandidates` sube a **8** — el número ya confirmado — y por eso el corte a 8 debe
hacerse de forma que **no favorezca un criterio**: ver (c).

**c) El corte a 8 se reparte, no se hace por llegada.** Cortar los 8 primeros por llegada
reintroduce el sesgo por la puerta de atrás. El corte se hace **intercalando** los mejores según
cada criterio activo: se toma el mejor por caminata final, el mejor por embarque, el mejor por
llegada, y se sigue alternando sin repetir hasta llenar 8 o agotar el frente. Así, sea cual sea el
criterio elegido después, su óptimo real está entre los 8.

Esta es la parte del diseño con más riesgo de escribirse mal y la que más mutaciones necesita.

**d) El filtro `extraTransferWorthSeconds` no se toca.** Sigue aplicándose sobre la cadena óptima
en llegada dentro de `alternatives`, exactamente como hoy; los candidatos de bajada añadidos por
(a) se incorporan después y pasan por el filtro de dominadas extendido. Se hace así para no
alterar el comportamiento que los tests actuales de `JourneyAlternativesTests` ya fijan.

### Alternativas descartadas

- **Reordenar en la vista las 4 que ya existen.** Era el plan anterior y es **insuficiente ahora
  que el criterio por defecto cambia**: §10.3 muestra que el candidato bueno puede no haberse
  generado nunca. Habría producido un selector que casi siempre devuelve el mismo orden.
- **Meter la caminata como tercer objetivo dentro de `RaptorEngine`.** Es lo correcto en teoría
  (frente de Pareto en llegada × transbordos × caminata dentro del motor) y es rediseñar el motor
  con toda su verificación por mutación. Innecesario: la caminata final solo depende de **qué
  parada de bajada se elige**, y esa decisión no está en el motor sino en la reconstrucción. Se
  arregla donde está el problema.
- **Replanificar al cambiar de criterio.** Un toque en el selector dispararía RAPTOR hasta 4 veces
  y hasta 16 lecturas de `shapePoint` en `buildTraces`. El criterio es presentación, no pregunta.

## 10.5 `JourneyOrdering`

```swift
// VigoCore/Sources/VigoCore/Planner/JourneyOrdering.swift   (nuevo)

public enum JourneyOrdering: String, Sendable, Hashable, CaseIterable, Codable {
    /// Por defecto. Lo que menos te hace andar al bajar.
    case leastWalkAtEnd
    /// El primer autobús que pasa por tu parada.
    case earliestBoarding
    /// Puerta a puerta, caminata final incluida. El orden que existía antes de la Fase 10.
    case earliestArrival

    public static let `default`: JourneyOrdering = .leastWalkAtEnd

    public var label: String {
        switch self {
        case .leastWalkAtEnd:  "Menos caminata"
        case .earliestBoarding: "Sale antes"
        case .earliestArrival:  "Llega antes"
        }
    }
}
```

Orden de comparación de cada criterio, desempates incluidos:

| Criterio | 1º | 2º | 3º |
|---|---|---|---|
| `leastWalkAtEnd` | caminata final ↑ | **caminata total** (`journey.walkingSeconds`) ↑ | llegada ↑ |
| `earliestBoarding` | embarque del primer bus ↑ | llegada ↑ | transbordos ↑ |
| `earliestArrival` | llegada ↑ | salida ↓ (menos espera) | transbordos ↑ |

`earliestArrival` reproduce **exactamente** el `sorted` que hay hoy en `ranked`, incluido el
desempate invertido en la salida. Es deliberado: si se elige ese criterio, la app se comporta como
antes de esta fase, y eso es comprobable con un test.

La caminata total como primer desempate de `leastWalkAtEnd` es la decisión ya confirmada: evita
premiar un trayecto que ahorra 200 m al final y añade 600 m al principio, sin dejar de respetar
que lo que se pidió es la caminata final.

Funciones auxiliares, todas puras y todas en `VigoCore`:

```swift
extension JourneyOrdering {
    public func apply(_ journeys: [Journey], limit: Int) -> [Journey]

    /// Segundos del último tramo a pie. Para un trayecto solo-a-pie, el trayecto entero.
    public static func egressWalkSeconds(_ journey: Journey) -> Int
    /// Embarque del primer bus. `nil` en un trayecto solo-a-pie, que se ordena al final.
    public static func firstBoarding(_ journey: Journey) -> Date?
}
```

**Se ordena por segundos, no por metros.** Los segundos vienen de `NearbyStop.distanceMetres`
pasado por `WalkModel.seconds(metres:)` — haversine real redondeado hacia arriba. Los metros del
tramo salen de `WalkModel.metres(forSeconds:)`, que la propia documentación del método llama cota
inferior porque deshace ese redondeo. El orden es el mismo (la conversión es monótona), pero no se
apoya en un número que el código marca como aproximado. En pantalla se siguen enseñando los
metros, ya etiquetados como estimación en toda la app.

## 10.6 Cambios por fichero

| Fichero | Cambio |
|---|---|
| `VigoCore/Planner/JourneyOrdering.swift` | **Nuevo.** Lo de §10.5 |
| `VigoCore/Planner/PlannerOptions.swift` | `maxCandidates = 8` («cuántas sobreviven al filtro antes de que la preferencia elija las visibles») y `maxEgressCandidates = 3` |
| `VigoCore/Planner/JourneyReconstruction.swift` | `bestEgress` → `egressCandidates` (frente de Pareto llegada × caminata, tope 3). `alternatives` reconstruye una por candidato y corta por `maxCandidates` |
| `VigoCore/Planner/JourneyPlanner.swift` | `ranked` se parte: `pareto(_:)` con `dominates` de cuatro ejes + corte intercalado a `maxCandidates`. La parada del bucle de `scan` pasa a mirar `maxCandidates` |
| `VigoCore/MapFlow/MapNavigationState.swift` | `ordering: JourneyOrdering`, `visibleJourneys`, `setOrdering(_:)` |
| `App/Views/Map/MapScreenModel.swift` | Preferencia en `UserDefaults`, clave `"route.ordering"`, patrón idéntico a `stopsVisible`. `buildTraces` construye para las visibles |
| `App/Views/Map/MapRouteSheet.swift` | `Menu` en el header de «Alternativas», no `Picker` segmentado — mismo argumento ya escrito para `departurePicker`: en una hoja el espacio horizontal es lo escaso |

Sobre `UserDefaults` frente a GRDB para la preferencia: el proyecto ya separa las dos cosas —
preferencia de presentación trivial y sin relación con los datos (`map.stopsVisible`) →
`UserDefaults`; datos del usuario que se crean, editan, ordenan y borran → SQLite. Un criterio de
ordenación es lo primero.

**Invariante en peligro:** `selectedAlternative` es un índice sobre la lista **visible**. Al
cambiar de criterio la lista se reordena, así que `setOrdering` debe volver a `0` y apagar
`isFollowing`, por el mismo argumento que ya está escrito en `selectAlternative(at:)`. Los tres
sitios que hoy leen `route.journeys` para dibujar (`currentJourney`, `MapRouteSheet.results`,
`MapScreenModel.selectedTraces`) pasan a leer `visibleJourneys`.

## 10.7 Pruebas y mutaciones

`JourneyOrderingTests.swift` (nuevo) con `Journey` construidos a mano — `Journey.init` y
`JourneyLeg` son públicos, no hace falta `Timetable`. Ampliación de `JourneyPlannerTests` y
`JourneyAlternativesTests` para lo del motor.

| Test | Mutación deliberada que debe tumbarlo |
|---|---|
| Con una parada de bajada que llega 3 min más tarde pero deja a 150 m en vez de a 700 m, **existe** una alternativa que la usa | **Dejar `bestEgress` como está** (una sola parada, la de llegada mínima). Es *la* mutación de esta fase: sin ella todo lo demás parece funcionar y el criterio por defecto es decorativo |
| El frente de bajada excluye una parada que llega más tarde **y** deja más lejos | Devolver todas las paradas de salida sin filtrar Pareto: el frente se llena de basura y el corte a 8 se come a los buenos |
| Con X (llega 9:40, 1 transbordo, 2 min a pie) e Y (llega 9:38, 0 transbordos, 15 min a pie), **ambas sobreviven** al filtro de dominadas | **Dejar `dominates` con tres ejes.** Reproduce literalmente el caso de §10.3 motivo 2 |
| Con 14 candidatos en el frente, el mejor por caminata final y el mejor por embarque **están los dos** entre los 8 que sobreviven | **Cortar por llegada** antes de intercalar. Es el sesgo por la puerta de atrás, y es invisible en cualquier test que no fuerce un frente grande |
| `leastWalkAtEnd` sobre 6 candidatos donde el de menos caminata es el 5º por llegada lo devuelve primero | Cortar antes de ordenar en `apply` |
| Dos candidatos con idéntica caminata final se desempatan por caminata total, y solo después por llegada | Quitar el desempate: el orden pasa a depender del orden de entrada |
| `leastWalkAtEnd` **no** coincide con `earliestArrival` en un caso donde el que menos anda llega más tarde | Implementar `leastWalkAtEnd` como `sorted(by: duration <)`. Pasa cualquier test ingenuo y falla este |
| `earliestBoarding` ordena por el embarque del primer bus, **no** por `Journey.departure` | Usar `journey.departure`. Falla solo cuando las caminatas de acceso difieren — construir el caso a propósito |
| `earliestArrival` reproduce byte a byte el orden que producía `ranked` antes de la fase | Invertir el desempate de la salida. Este test es el que garantiza que la fase no cambia el comportamiento de quien elija el criterio antiguo |
| `egressWalkSeconds` de un trayecto solo-a-pie devuelve el trayecto entero, no 0 | Buscar el último `.walk` **entre paradas** en lugar del último tramo |
| Cambiar de criterio con la alternativa 3 resaltada deja `selectedAlternative == 0` e `isFollowing == false` (en `MapNavigationStateTests`) | Conservar el índice al reordenar. Sin esto la cámara apunta a un trayecto distinto del resaltado |

**No automatizable:** que el `Menu` con tres opciones quepa en el header sin partir la fila en un
iPhone pequeño. Comprobación en dispositivo.

---

# FASE 11 — Trayecto activo persistente

## 11.1 Dónde vive el estado

**Decisión: GRDB, en la misma base de datos, migración `v3`.**

- **`@SceneStorage`.** Descartada sin discusión. Apple documenta su contenido como *state
  restoration* y el sistema lo descarta cuando el usuario mata la app desde el conmutador — que
  es literalmente uno de los casos que el encargo exige sobrevivir. Sería prometer persistencia
  y no darla.
- **`UserDefaults`.** Sobrevive a todo lo necesario y bastaría para un blob JSON. Se descarta por
  tres razones concretas de *este* proyecto: (1) `AppEnvironment` ya trata la base de datos como
  el único dueño de los datos del usuario y `UserDefaults` como el sitio de una preferencia
  trivial; un trayecto en curso no es una preferencia. (2) Hay que leerlo desde sitios que no son
  la UI — el manejador de notificaciones de la Fase 13, y una posible relanzada en frío. (3) La
  pregunta «¿este trayecto sigue siendo válido?» se cruza con `stop` y `feedMetadata`: en SQLite
  es una lectura, en `UserDefaults` es leer un blob y ir igualmente a SQLite.
- **Fichero JSON en Application Support.** `UserDefaults` con más código y sin transacciones.

## 11.2 La migración `v3`, entera y de una vez

**La migración `v3` crea las dos tablas nuevas del plan: `activeJourney` y `recentSearch`.** Es
la decisión explícita del propietario de no encadenar migraciones. `recentSearch` queda creada
pero sin usar hasta la Fase 12, lo cual es inofensivo — una tabla vacía no cuesta nada — y evita
una `v4` dos semanas después sobre datos reales.

```sql
-- activeJourney
id            TEXT PRIMARY KEY        -- constante "current": como mucho una fila
startedAt     DATETIME NOT NULL
state         TEXT NOT NULL           -- "active" | "stale"
destinationName      TEXT NOT NULL
destinationStopID    TEXT             -- NULL si el destino no era una parada
destinationLatitude  DOUBLE NOT NULL
destinationLongitude DOUBLE NOT NULL
scheduledArrival     DATETIME NOT NULL
payload       BLOB NOT NULL           -- JSON de ActiveJourneySnapshot
```

- **`id` constante `"current"`, no `UUID`.** Solo puede haber un trayecto activo. Codificarlo en
  la clave primaria hace que empezar uno sea un `INSERT OR REPLACE` y que tener dos sea
  *imposible*, en vez de depender de que el código recuerde borrar el anterior.
- **Sin clave foránea a `stop`.** Por lo mismo que dice el comentario de la migración `v2`: el
  importador borra esa tabla entera en cada refresco, y la FK o cascadearía el trayecto o
  bloquearía el import.
- **Columnas planas duplicando parte del blob.** Denormalización deliberada: la Fase 13 necesita
  el destino sin deserializar un trayecto entero. El precedente es `cachedArrivals`, que ya
  guarda `payload` junto a columnas consultables.

La definición de `recentSearch` está en §12.3.

## 11.3 Qué se guarda

Hay que reconstruir el trayecto tras un cierre en frío y, posiblemente, tras una reimportación
que ha borrado y reescrito `stop`.

**Decisión: instantánea autosuficiente, no referencia. El trayecto activo no se replanifica
nunca.** Es lo contrario de `SavedJourney` y es a propósito: un trayecto guardado es *un par
origen-destino para replanificar*; un trayecto activo es *este autobús, en el que ya voy
sentado*. Replanificarlo al abrir la app no tendría sentido — no puedes cambiar de bus a mitad
de viaje porque haya salido algo mejor.

Se aplica sin embargo **la misma regla de anclaje que la Fase 4 fijó**: cada parada se guarda como
`stopID` **más coordenada de respaldo**, nunca como un `Stop` serializado. Al leer se resuelve el
`stopID` contra `stop`; si ya no está, se cae a la coordenada y el trayecto sigue siendo
dibujable y avisable. Se reutilizan `SavedPlaceAnchor` y `SavedPlaceAnchorInput`, que ya modelan
esto incluyendo `.orphanedStop`.

```swift
// VigoCore/ActiveJourney/ActiveJourneySnapshot.swift   (nuevo)
public struct ActiveJourneySnapshot: Codable, Sendable, Hashable {
    public struct StopRef: Codable, Sendable, Hashable {
        public let stopID: StopID?          // nil si nunca fue parada del feed
        public let name: String
        public let latitude: Double
        public let longitude: Double
    }
    public struct Ride: Codable, Sendable, Hashable {
        public let routeShortName: String
        public let headsign: String?
        public let tripID: TripID?          // informativo; puede no existir mañana
        public let board: StopRef
        public let alight: StopRef
        public let intermediate: [StopRef]  // la Fase 13 necesita "la parada anterior"
        public let scheduledDeparture: Date
        public let scheduledArrival: Date
    }
    public let originName: String
    public let destination: StopRef
    public let rides: [Ride]
    public let egressWalkSeconds: Int
    public let scheduledDeparture: Date
    public let scheduledArrival: Date
    public let transfers: Int

    public init(_ journey: Journey, originLabel: String, destinationLabel: String)
}
```

Un `Codable` **propio**, no `Journey` serializado: `Journey` y `JourneyLeg` son tipos vivos del
planificador y van a cambiar — y la Fase 10 ya los está tocando. Un blob persistido que dependa de
su forma convierte cualquier refactor en una migración de datos. `intermediateStops` ya viene en
`JourneyLeg.ride`, así que la instantánea no pierde nada que la Fase 13 necesite.

## 11.4 Caducidad

Un trayecto que nadie cierra no puede quedarse activo para siempre, y **tampoco puede borrarse
solo en silencio** — eso sería la app decidiendo por el usuario que ya ha llegado.

**Dos estados y ninguna eliminación automática:**

```swift
public enum ActiveJourneyStaleness: Sendable, Hashable {
    case active
    case stale(since: Date)
}
public extension ActiveJourneySnapshot {
    /// Pura: `now` entra por parámetro, como `FirstBoardingMatch.match`.
    func staleness(now: Date, grace: TimeInterval = 90 * 60) -> ActiveJourneyStaleness
}
```

Mientras `now <= scheduledArrival + grace` → `.active`. Pasado eso → `.stale`, y la cápsula cambia
de «Trayecto en curso» a «¿Sigues en este trayecto?» con **Terminar** y **Sigo en él** (que empuja
la ventana otro `grace`). Los 90 minutos confirmados son deliberadamente generosos: el trayecto de
bus más largo de Vitrasa está muy por debajo, y el margen cubre bajarse, caminar y no tocar el
móvil en un rato. Preguntar de más molesta; cerrar de menos pierde el estado.

Al pasar a `.stale` se **cancelan los avisos pendientes** de la Fase 13. Un aviso de bajada de un
trayecto de ayer es peor que ningún aviso.

**La ventana de 7 días del GTFS no afecta a un trayecto activo.** Ese es el efecto de guardar una
instantánea: el trayecto en curso no consulta el feed. Lo único que puede degradarse es el trazado
en el mapa (los `shapePoint` sí se reimportan) y la resolución de un `stopID` a `Stop`, y ambos
tienen caída elegante. Conviene decirlo explícitamente en `ESTADO.md`, porque es contraintuitivo.

## 11.5 UI

**Una cápsula persistente en `RootView`, no en `MapScreen`.** El requisito es que siga visible al
cambiar de pestaña; `MapScreen` ya usa `safeAreaInset(edge: .bottom)` para su barra de búsqueda,
pero eso vive dentro de la pestaña Mapa. La barra de trayecto activo va en el `TabView` de
`RootView`, por encima de la barra de pestañas, visible en Mapa y en Favoritas.

Forma: una línea baja, no una tarjeta. Línea + parada de bajada + hora prevista + chevron. Al
tocarla abre el mapa con ese trayecto en `.journeyDetail`. Menú contextual o swipe con **Terminar**
y **Cancelar**.

**Terminar y Cancelar se distinguen en la UI y no en los datos**: ambos borran la fila. Sin
histórico —decisión confirmada— no hay nada que hacer con la distinción. `Cancelar` pide
confirmación destructiva; `Terminar` no.

**Iniciar un trayecto no enciende `isFollowing`.** Son cosas distintas con costes distintos: el
seguimiento mantiene la pantalla encendida y sube la precisión del GPS, y muere al salir; el
trayecto activo persiste y no cuesta batería.

## 11.6 Cambios por fichero

| Fichero | Cambio |
|---|---|
| `VigoCore/Persistence/AppDatabase.swift` | Migración `v3`: `activeJourney` **y** `recentSearch` |
| `VigoCore/ActiveJourney/ActiveJourneySnapshot.swift` | **Nuevo** |
| `VigoCore/ActiveJourney/ActiveJourneyRecord.swift` | **Nuevo.** Fila GRDB `internal`, como `SavedPlaceRow` |
| `VigoCore/Persistence/TransitRepository.swift` | `// MARK: - Trayecto activo`: `activeJourney()`, `startActiveJourney(_:)`, `endActiveJourney()`, `markActiveJourneyStale(at:)`, `extendActiveJourney(to:)` |
| `App/ActiveJourneyStore.swift` | **Nuevo.** `@MainActor @Observable`, calcado de `SavedPlacesStore`; recalcula `staleness` al volver a primer plano |
| `App/AppEnvironment.swift` | Construye y expone `activeJourney` |
| `App/Views/RootView.swift` | La cápsula persistente |
| `App/Views/ActiveJourneyBar.swift` | **Nuevo** |
| `App/Views/Map/MapRouteSheet.swift` | «He subido a este bus» en `MapJourneyLegsView`, junto a «Seguir en el mapa» |
| `App/Views/Map/MapScreenModel.swift` | `startActiveJourney()` sobre `state.currentJourney` |

## 11.7 Pruebas y mutaciones

| Test | Mutación deliberada que debe tumbarlo |
|---|---|
| Guardar un trayecto, **reimportar el feed** (que vacía `stop`), y comprobar que sigue leyéndose con destino resoluble por coordenada | **Persistir el `Stop` entero** en vez de `stopID` + respaldo. Reproduce el fallo real que la Fase 4 ya sufrió con lugares guardados |
| Iniciar un segundo trayecto sin terminar el primero deja **exactamente uno**, el segundo | Usar `UUID` como `id`. El test falla con dos filas, y ese es el motivo de la clave constante |
| `staleness` con `now == scheduledArrival + 60 s` → `.active` | Comparar sin gracia |
| `staleness` con `now == scheduledArrival + grace + 1 s` → `.stale` | **Comparar contra `scheduledDeparture`** en vez de `scheduledArrival`: un trayecto largo caducaría con el usuario dentro del bus. Es el error más plausible de escribir |
| `extendActiveJourney` devuelve a `.active` **y** mueve la ventana | Cambiar el estado sin mover la fecha: vuelve a `.stale` al instante siguiente |
| Round-trip JSON con 2 transbordos y paradas intermedias | Omitir `intermediate` del `Codable`: pasa desapercibido hasta que la Fase 13 no encuentra la parada anterior |
| Migración `v3` sobre una `v2` con lugares y trayectos guardados: sobreviven | Patrón ya establecido en `MigrationTests` |
| `endActiveJourney` sin trayecto activo no lanza | Trivial y real |

---

# FASE 12 — Búsquedas recientes (máximo 10)

Depende de la Fase 11 **solo por la migración**: la tabla se crea allí. La funcionalidad es
independiente y podría implementarse antes que el trayecto activo si conviniera.

## 12.1 Qué es exactamente «una búsqueda»

`MapSearchSheet` tiene un embudo único: **`private func pick(_ place: MapPlace)`**. Todo lo que se
elige en el buscador —una parada de los resultados, una dirección resuelta, «Mi ubicación», un
punto elegido en el mapa, un lugar guardado, una parada favorita, una parada de «Cerca de ti»—
pasa por ahí. Ese es el sitio donde se registra un reciente, y es lo que hace que esta fase sea
pequeña.

**Decisión: se guarda el lugar elegido, no el par origen-destino.** Tres razones:

1. **El par ya existe como funcionalidad:** `SavedJourney` es exactamente «este origen con este
   destino», con nombre, edición y orden. Unos recientes de pares serían una segunda versión peor
   de algo que ya está.
2. **En dos de los tres propósitos no hay par.** `MapSearchSheet.Purpose` tiene `.explore`,
   `.endpoint(role)` y `.standalone(title:)`. En `.standalone` se está eligiendo el ancla de un
   lugar guardado; no hay origen ni destino que emparejar. Un reciente por par solo existiría en
   un tercio de los usos del buscador.
3. **El estado vacío del buscador ya es una lista de lugares** (Trayectos guardados, Lugares
   guardados, Paradas favoritas, Cerca de ti, Líneas). «Recientes» encaja como una sección más,
   arriba del todo, y se puede usar desde cualquier propósito.

**Qué NO se guarda, y por qué:**

- **`.currentLocation`.** No es una búsqueda, es una cosa viva. Guardar una coordenada congelada
  bajo la etiqueta «Mi ubicación» sería mentira dos horas después. Además la fila «Mi ubicación»
  ya está siempre en la cabecera del buscador.
- **`.savedPlace`.** Ya tiene su propia sección permanente. Duplicarlo es ruido.

Todo lo demás se guarda: `.stop`, `.address`, `.droppedPin`. Un punto suelto del mapa **sí** se
guarda: volver a él es justo lo que cuesta trabajo sin recientes.

**Corrección (H-46, auditoría del buscador, `AUDITORIA-BUSCADOR.md`): `.pointOfInterest` no
pertenece a esta lista.** Ese origen solo lo produce `MapScreenModel.selectPointOfInterest`, al
tocar un POI de Apple **directamente en el mapa** — nunca pasa por `MapSearchSheet` ni por
`pick(_:)`, así que no hay ningún sitio donde esta fase lo pudiera interceptar tal y como está
descrita. Antes de implementar, decidir una de dos: (a) dejar los POI fuera de «Recientes»,
igual que `.currentLocation`, con la misma razón de fondo — no es una búsqueda; o (b) si se
quieren dentro (un POI es tan "un sitio al que costó volver" como un pin suelto), el punto de
registro no puede ser `pick(_:)` — tendría que ser `MapNavigationState.select`, que es el embudo
real de todo lo que acaba en una ficha del mapa, tocado desde el buscador o no. Elegir (b)
cambia además el «Cambios por fichero» de más abajo: el registro ya no viviría solo en
`MapSearchSheet.swift`.

## 12.2 Deduplicación, expulsión e interacción con lo ya guardado

**Identidad (`dedupKey`, columna TEXT con índice UNIQUE):**

- Si el lugar es una parada → `"stop:<stopID>"`.
- Si no → `"pt:<lat>:<lon>:<nombre plegado>"`, con la coordenada **redondeada a 4 decimales
  (~11 m)** y el nombre pasado por `TextNormalization.searchFolded`. El redondeo a 4 decimales no
  es un número inventado: es exactamente el que `MapSearchSheet.roundedCoordinate` ya usa para no
  relanzar la consulta de «Cerca de ti» con cada temblor del GPS.

Elegir dos veces lo mismo **actualiza `lastUsedAt`**, no inserta. Es un `INSERT ... ON CONFLICT
(dedupKey) DO UPDATE SET lastUsedAt = ...`, en una transacción.

**Expulsión: LRU por `lastUsedAt`, tope 10.** Tras cada inserción, se borran las filas cuyo
`lastUsedAt` quede fuera de las 10 más recientes. Por *uso*, no por creación: una parada buscada
hace un mes y usada esta mañana se queda; una buscada ayer una sola vez se va antes. Es lo que se
pidió y es lo que hace útil una lista de 10.

**Interacción con lugares guardados y favoritas: se filtra al leer, nunca al escribir.**

El estado de «guardado» y «favorito» cambia *después* de la búsqueda: se busca una parada, se usa,
y tres días después se marca favorita. Filtrar en el momento de escribir congelaría una decisión
que aún no se había tomado. Así que `recentSearches()` devuelve la lista completa y la vista
descarta los que ya aparecen más abajo:

- un reciente cuyo `stopID` está en `environment.favourites.stops` → no se dibuja en «Recientes»;
- un reciente cuya `dedupKey` coincide con el ancla de un `SavedPlace` → tampoco.

Consecuencia aceptada y correcta: guardar un lugar hace que desaparezca de «Recientes» y aparezca
en «Lugares guardados». Es lo que se espera, y la fila no se pierde — vuelve sola si alguna vez se
borra el lugar guardado.

**`stopID` huérfano tras la reimportación semanal.** Mismo anclaje que todo lo demás en este
proyecto: `stopID` **más coordenada de respaldo**, resuelto en cada lectura con
`SavedPlaceAnchor`. Si el `stopID` ya no está en el feed, el reciente sigue siendo usable como
coordenada — se puede seguir tocando y sigue llevando al mismo sitio del mapa. **No se borra el
reciente huérfano**: se dibuja con el nombre que se guardó. Borrarlo en silencio sería la app
decidiendo que un sitio al que fuiste la semana pasada ya no existe.

## 12.3 Esquema (dentro de la migración `v3`)

```sql
recentSearch
  dedupKey    TEXT PRIMARY KEY        -- "stop:<id>" | "pt:<lat>:<lon>:<nombre>"
  name        TEXT NOT NULL
  subtitle    TEXT
  symbolName  TEXT NOT NULL           -- de MapPlace.symbolName
  originKind  TEXT NOT NULL           -- "stop" | "address" | "poi" | "pin"
  stopID      TEXT                    -- NULL salvo originKind == "stop"
  latitude    DOUBLE NOT NULL         -- respaldo, siempre poblado
  longitude   DOUBLE NOT NULL
  lastUsedAt  DATETIME NOT NULL
CREATE INDEX recentSearch_lastUsedAt ON recentSearch(lastUsedAt);
```

`dedupKey` como clave primaria y no como índice UNIQUE aparte: la deduplicación *es* la identidad
de la fila, y ponerlo en la PK hace que un duplicado sea imposible en vez de improbable. Es el
mismo argumento que la clave constante `"current"` de `activeJourney`.

Sin clave foránea a `stop`, por lo de siempre.

## 12.4 Cambios por fichero

| Fichero | Cambio |
|---|---|
| `VigoCore/Persistence/AppDatabase.swift` | La tabla ya creada en `v3` (Fase 11) |
| `VigoCore/Recents/RecentSearch.swift` | **Nuevo.** El modelo público, con `anchor: SavedPlaceAnchor` resuelto y `place: Place` para pasárselo a quien lo pida |
| `VigoCore/Recents/RecentSearchKey.swift` | **Nuevo y puro.** `dedupKey(for:)` — la función de identidad, con el redondeo y el plegado. Aislada porque es lo único que hay que verificar con mutaciones |
| `VigoCore/Persistence/TransitRepository.swift` | `// MARK: - Búsquedas recientes`: `recentSearches(limit:)`, `recordRecentSearch(_:at:)`, `deleteRecentSearch(key:)`, `clearRecentSearches()`. El recorte a 10 vive dentro de `recordRecentSearch`, en la misma transacción |
| `App/RecentSearchesStore.swift` | **Nuevo.** `@MainActor @Observable`, patrón `SavedPlacesStore` |
| `App/AppEnvironment.swift` | Expone `recents` y lo recarga en `refreshFeed()` junto a `favourites` y `savedPlaces` — un reimport puede haber dejado huérfanos |
| `App/Views/Map/MapSearchSheet.swift` | `pick(_:)` registra el reciente (salvo `.currentLocation` y `.savedPlace`). Sección «Recientes» la primera del estado vacío, con swipe para borrar una y un «Borrar recientes» al final |

**El registro va en `pick(_:)` y no en cada fila.** El buscador ya sufrió una vez el problema de
tener la misma lógica en dos sitios — la Fase 7 existe por eso — así que un solo embudo, no una
llamada a `recordRecentSearch` copiada en cada fila.

**Corrección (H-46): la enumeración de «seis sitios (parada, dirección, POI, pin, cercana,
favorita)» no se corresponde con el código de hoy.** Comprobado contra
`App/ILoveVigoRoutes/Views/Map/MapSearchSheet.swift` tal y como queda tras la auditoría del
buscador:

- «POI» no pertenece a esta lista — ver la corrección de §12.1.
- «Parada» y «favorita» son la **misma** llamada: `stopRow(_:)` sirve tanto la sección
  «Paradas» de los resultados como «Paradas favoritas» del estado vacío. No son dos sitios,
  son una función usada en dos secciones.
- Falta «lugar guardado»: la fila de `environment.savedPlaces.places` en el estado vacío
  también llama a `pick(_:)` (`pick(.savedPlace(place))`), y no estaba en la lista original.
- Desde la corrección de H-34 en la misma auditoría, el extremo de un **trayecto guardado**
  elegido con `purpose == .endpoint(role)` también pasa por `pick(_:)` — antes se saltaba el
  embudo llamando a `onPick` directamente. `purpose == .explore` sigue sin pasar por aquí, y
  no debe: planifica el trayecto entero con `onPickJourney`, no hay un único `MapPlace` que
  registrar.

En total, a fecha de esta corrección: `pickCurrentLocation()`, el cierre de
`MapPointPickerView` (parada, dirección, favorita comparten `stopRow(_:)`), `nearbyRow(_:)`,
`addressRow(_:_:)`, la fila de lugar guardado, y el extremo de trayecto guardado en
`.endpoint`. Volver a comprobar contra el código en el momento de implementar esta fase: es
exactamente el tipo de lista que se desactualiza con el primer cambio que la toque de pasada.

## 12.5 Pruebas y mutaciones

`RecentSearchTests.swift` (nuevo), sobre `AppDatabase.inMemory()`.

| Test | Mutación deliberada que debe tumbarlo |
|---|---|
| Registrar 12 recientes distintos deja **10**, y los que quedan son los 10 de `lastUsedAt` más alto | Recortar por fecha de **creación** en vez de por último uso. Pasa el test de «quedan 10» y falla este |
| Registrar A, luego B…J, luego **A otra vez**: A se queda y B es el que se cae | **La mutación central.** Si el recorte ordena por creación, A (el más antiguo de creación) se expulsa a pesar de acabar de usarse. Es exactamente el fallo que hace inútil una lista de 10 |
| Elegir la misma parada dos veces deja **una** fila con `lastUsedAt` actualizado | Insertar sin `ON CONFLICT`: o revienta la PK o duplica |
| Dos puntos a 8 m de distancia con el mismo nombre → **una** fila; a 40 m → **dos** | Redondear a 2 decimales (~1,1 km): media Vigo colapsa en una fila. O no redondear: cada temblor del GPS crea un reciente |
| Dos direcciones con el mismo nombre y acentos distintos → una fila | No plegar el nombre con `TextNormalization.searchFolded` |
| Un reciente de parada cuyo `stopID` desaparece tras reimportar sigue leyéndose, con `anchor.isOrphaned == true` y coordenada usable | **Borrar los huérfanos al reimportar**, o guardar el `Stop` entero. Mismo par de mutaciones que en la Fase 11, y por el mismo motivo |
| `recordRecentSearch` con un `MapPlace` de origen `.currentLocation` o `.savedPlace` **no** escribe nada | Registrar todo sin filtrar: la lista se llena de «Mi ubicación» repetido |
| El recorte y la inserción ocurren en **una** transacción | Hacerlos en dos: una lectura concurrente puede ver 11 filas. Difícil de provocar; el test comprueba que la escritura es un solo `write` |

**No automatizable:** el orden visual de la sección respecto a Lugares guardados y Favoritas, y
que el swipe de borrado no choque con `favouriteActions`, que ya ocupa el borde principal de las
filas de parada. Comprobación en dispositivo — y ojo, que en `stopRow` el borde `trailing` ya lo
usa «Guardar».

---

# FASE 13 — Aviso de llegada al destino

**Depende de la Fase 11.** Sin trayecto activo no hay destino al que avisar, ni dónde guardar qué
avisos están armados, ni forma de que un aviso sobreviva a un cierre en frío. No empezar antes de
que la 9 esté cerrada y comprobada en dispositivo.

**Permiso de ubicación «Siempre»: concedido.** El diseño se construye sobre eso.

## 13.1 «Push» no; notificación local

- **Push (remota)** = APNs: un **servidor** que sepa dónde estás y decida cuándo avisarte, un
  token de dispositivo, un certificado de Apple, y tu ubicación **saliendo del teléfono**. Rompe
  frontalmente lo que promete `README.md` — sin cuentas, sin telemetría — y lo que dice el propio
  `Info.plist`: «La ubicación no sale del dispositivo».
- **Local** = `UNUserNotificationCenter`: la app programa la alerta en el propio teléfono y el
  sistema la muestra a la hora o en el lugar indicado, **aunque la app esté cerrada o el teléfono
  se haya reiniciado**. Sin servidor, sin red, sin cuenta.

Para «avísame cuando esté llegando», la local no es una aproximación: es estrictamente mejor.
Menos latencia (no hay viaje al servidor), más fiabilidad (no depende de red) y cero coste de
privacidad.

## 13.2 Camino principal: `UNLocationNotificationTrigger`

Notificación local cuyo disparador es una región geográfica, gestionada íntegramente por el
sistema.

- **Permiso:** «Siempre» (`authorizedAlways`). Concedido.
- **Modo en segundo plano:** **ninguno**. No hay que tocar `UIBackgroundModes`, que hoy solo lleva
  `processing` para el refresco del GTFS. El sistema muestra la notificación por su cuenta sin que
  la app llegue a ejecutarse.
- **Batería: muy baja.** El geovallado lo resuelve el sistema con torres y Wi-Fi, no con GPS
  continuo. Es el mecanismo pensado exactamente para esto.
- **Límites:** 20 regiones por app, compartidas con las de `CLLocationManager`. Se arman 2.
- **Precisión real, sin adornos:** 100–200 m de incertidumbre y **latencia de decenas de
  segundos**. El sistema no comprueba continuamente. Esta es la limitación de fondo de toda la
  fase y la razón del umbral de §13.4.

Descartados como mecanismo principal, con su motivo:

- **`CLMonitor` + `CircularGeographicCondition`** (A). Mismo permiso y misma física, pero **exige
  que la app se ejecute** para entregar el evento. Más cosas que pueden fallar a cambio de una
  única ventaja: poder *filtrar* el evento antes de avisar. Se reserva para el caso de §13.4
  (líneas con bucle) si aparece en la práctica.
- **Ubicación continua en segundo plano** (`CLBackgroundActivitySession` o
  `UIBackgroundModes = ["location"]`). GPS despierto todo el trayecto: **batería alta**, indicador
  azul permanente, y **no sobrevive a que se mate la app** — que es justo lo que la Fase 11 exige.
  Se descarta como mecanismo de fondo. Solo tendría sentido para «te has pasado de parada»
  (§13.5), que no se implementa.

## 13.3 Red de seguridad: aviso por tiempo

`UNTimeIntervalNotificationTrigger` calculado desde `scheduledArrival` de la instantánea. **Se
programa siempre**, aunque el permiso «Siempre» esté concedido.

- Permiso de ubicación: **ninguno**. Modo en segundo plano: **ninguno**. Batería: **cero**.
- Cubre los dos agujeros de la geovalla: **pérdida de señal** (túneles) y que el permiso se
  revoque en algún momento.
- Su defecto es real y hay que decirlo: el GTFS es horario teórico y en hora punta un desfase de
  5–10 minutos es normal. **El tiempo real no lo arregla**: `FirstBoardingMatch` solo cubre la
  parada de embarque, y su propia documentación dice que el resto del trayecto sigue siendo
  horario. No hay fuente que diga dónde va el bus a mitad de recorrido.

**Se programa deliberadamente tarde** respecto al momento estimado de la geovalla, para que en el
caso normal la geovalla llegue primero. Al entregarse cualquiera de los dos, la app retira el otro
con `removePendingNotificationRequests` en cuanto despierte o se abra. Si no llega a despertar, el
peor caso es un aviso duplicado con unos minutos de diferencia: molesto, no dañino.

## 13.4 El criterio de disparo

Avisar al llegar es inútil: entre que suena, sacas el móvil, lo lees y te levantas, el bus ya está
parando. Y con 100–200 m de incertidumbre y decenas de segundos de latencia, el aviso «exacto»
llegaría además tarde.

**Dos avisos, y la geometría sale de las paradas del propio trayecto, no de un radio fijo.**

```
Preaviso  → "Bajas en la próxima. Prepárate."
Inminente → "Tu parada: <nombre>."
```

**Regla para elegir la parada del preaviso** — esto es lo que resuelve el caso de las paradas
juntas del centro:

> Recorriendo hacia atrás desde la parada de bajada por `intermediate` del último tramo en bus, se
> elige **la primera parada que esté a 400 m o más** de la de bajada. Si ninguna lo está, o el
> tramo tiene menos de 3 paradas, **no hay preaviso**: solo el aviso inminente.

Por qué así y no «una parada antes»:

- En el centro de Vigo hay paradas a 150–200 m. «Una parada antes» daría un preaviso 40 segundos
  antes del inminente: dos alertas para lo mismo, ninguna útil.
- En Beiramar o subiendo a Castrelos las paradas están a 600–800 m: una parada antes son dos
  minutos largos, que es lo que se quiere.
- 400 m ≈ un minuto de bus y cinco de caminata, y es **el doble de la incertidumbre máxima de la
  geovalla** — el margen que hace que el preaviso siga cayendo antes que el inminente incluso en el
  peor caso.

**Radio de las geovallas: 250 m** en ambas. Por debajo de ~150 m iOS deja de ser fiable; 250 m es
bastante para entrar desde cualquier aproximación y poco para no dispararse a una manzana.

**Trayectos cortos:** si al armar los avisos el tramo final tiene menos de 3 paradas, o la llegada
prevista está a menos de 4 minutos, **solo aviso inminente**. Evita el ridículo de que el preaviso
suene antes de que te dé tiempo a sentarte.

### Casos límite

| Caso | Qué se hace |
|---|---|
| **Paradas muy juntas** | La regla de los 400 m retrocede hasta encontrar separación real, o suprime el preaviso |
| **Trayecto corto** | Solo inminente si < 3 paradas o < 4 min |
| **Túnel / sin señal** | La red de seguridad por tiempo cubre el hueco. Además iOS suele entregar la entrada de región con retraso al recuperar posición, así que a menudo llega igual, tarde |
| **La línea pasa cerca del destino antes de tiempo** (bucles, líneas que pasan dos veces) | Falso positivo. Con `UNLocationNotificationTrigger` **no se puede filtrar**: el sistema muestra la notificación sin consultarnos. Es la única razón concreta por la que podría hacer falta migrar el aviso inminente a `CLMonitor`, que sí permite comprobar la hora al despertar. **Se decide en dispositivo, con tus líneas** (§6, P6) |
| **Te pasas de parada** | §13.5 |
| **Te bajas antes** | «Terminar» en la cápsula retira todos los avisos. Esa es la razón de que Terminar exista |
| **El trayecto caduca a `.stale`** | `markActiveJourneyStale` retira los pendientes |

## 13.5 «Te has pasado de parada»

Solo sale bien con ubicación continua, que está descartada. Con geovallas se podría añadir una
condición de **salida** del círculo del destino, pero esa salida también se dispara cuando te
bajas, caminas 250 m hasta el portal y no has pulsado «Terminar» — que es el caso **normal**.
Distinguirlo exige velocidad o rumbo, o sea, GPS continuo.

**Recomendación: no implementarlo.** Queda anotado como candidato futuro ligado a un interruptor
explícito de «seguimiento preciso». Prometer una detección de pasada que falla la mitad de las
veces es peor que no tenerla.

## 13.6 Cambios por fichero

| Fichero | Cambio |
|---|---|
| `App/Info.plist` | `NSLocationAlwaysAndWhenInUseUsageDescription`, en la línea del texto que ya hay: qué se hace y que no sale del dispositivo. **`UIBackgroundModes` no se toca** |
| `VigoCore/ActiveJourney/ArrivalAlertPlan.swift` | **Nuevo y puro.** `build(snapshot:options:) -> [ArrivalAlert]`. **Toda** la lógica de §13.4, sin importar `CoreLocation` ni `UserNotifications`, para que `swift test` la ejecute entera en el Mac |
| `VigoCore/ActiveJourney/ArrivalAlertOptions.swift` | **Nuevo.** Los números como política, patrón `PlannerOptions`: `preavisoSeparationMetres = 400`, `geofenceRadiusMetres = 250`, `minStopsForPreaviso = 3`, `minMinutesForPreaviso = 4`, `timeFallbackSlack` |
| `App/ArrivalAlertScheduler.swift` | **Nuevo.** La parte sucia: permisos, traducir `[ArrivalAlert]` a `UNNotificationRequest`, cancelar y reconciliar al volver a primer plano |
| `App/LocationProvider.swift` | `requestAlwaysAuthorizationIfNeeded()`. **El `start()` actual, con `desiredAccuracy` a 100 m, no se toca**: la geovalla no depende de él |
| `App/AppDelegate.swift` | Delegado de `UNUserNotificationCenter` para presentar el aviso en primer plano y reconciliar al tocarlo |
| `App/ActiveJourneyStore.swift` | Arma los avisos al iniciar; los retira al terminar, cancelar o caducar |
| `App/Views/ActiveJourneyBar.swift` | Interruptor de aviso |
| `App/Views/Map/MapRouteSheet.swift` | **Actualizar el pie que hoy dice** «Sin avisos de bajada: el horario por sí solo no puede prometerlos.» Deja de ser cierto y no puede quedarse |

Aunque el permiso esté concedido, la degradación se implementa igual: si algún día se revoca, la
UI **no se calla**. Dice qué mecanismo está activo — *«Aviso por horario. Con permiso de ubicación
siempre, avisaría por posición real, que es bastante más fiable.»* Misma regla que `DataKindBadge`
aplica al tiempo real frente al horario.

## 13.7 Pruebas y mutaciones

Todo lo testeable vive en `ArrivalAlertPlan`, puro a propósito.

| Test | Mutación deliberada que debe tumbarlo |
|---|---|
| Tramo con paradas a 180 m: el preaviso **no** cae en la penúltima, sino en la primera a ≥400 m | **Coger la penúltima sin comprobar separación.** Es la implementación ingenua, pasa cualquier test de «hay dos avisos» y produce el comportamiento inútil del centro de Vigo |
| Tramo de 2 paradas: **un solo** aviso | Generar siempre dos |
| Llegada prevista a 3 minutos: un solo aviso | Comparar el umbral contra la duración **total** del trayecto en vez de contra lo que queda del tramo final |
| Ninguna parada del tramo llega a 400 m: un solo aviso, **sin** caer en la parada de embarque | Que el recorrido hacia atrás, al agotarse, devuelva la primera del tramo: el preaviso saltaría al principio del trayecto |
| El aviso de tiempo queda programado **después** del momento estimado de la geovalla | Invertir el signo del margen: el de tiempo llegaría siempre primero y la geovalla no serviría de nada. Nada más lo detectaría |
| Con transbordo, los avisos se calculan sobre el **último** tramo en bus | Usar `rides.first`. Invisible en trayectos directos, que son los que se probarían a mano |

**Explícitamente no automatizable, y hay que escribirlo así en `ESTADO.md`:** que la geovalla
dispare de verdad y con cuánto retraso; que la notificación llegue con la app terminada y tras
reiniciar el teléfono; el comportamiento en los túneles de Vigo. No hay forma de simularlo con
`swift test`, y fingir que sí la hay sería peor que no tener tests.

---

# §5 — Orden de implementación

```
Fase 8 (caminatas + actualizar) ──→ Fase 10 (ordenación: el criterio por defecto
                                             es la caminata, y hay que poder verla)
Fase 9 (horarios de línea) ─── independiente
Fase 11 (trayecto activo + migración v3) ──┬──→ Fase 12 (recientes, solo por la migración)
                                           └──→ Fase 13 (avisos, dependencia real)
```

**8 → 9 → 10 → 11 → 12 → 13.** Las razones del orden:

1. **Las fases 8 y 9 son defectos de lo entregado, no funcionalidad nueva**, y las dos son
   pequeñas. Arreglar primero lo que ya molesta al usarla vale más que añadir encima.
2. **La Fase 10 no puede ir antes que la 8** (§10.0): su criterio por defecto ordena por una
   caminata que hoy no se dibuja.
3. **La Fase 10 es la única grande sin permisos, sin migración y sin dispositivo**, y se verifica
   casi entera con `swift test` en el Mac. Ha crecido respecto al plan anterior (§10.3), pero
   sigue siendo la que antes deja algo utilizable de las que quedan.
4. **La Fase 13 es la más incierta.** Empezar por ella sería descubrir a mitad que la geovalla es
   más lenta de lo esperado con todo lo demás sin hacer. Dejándola última, si hay que renegociar
   su alcance, el resto ya está entregado.

Dentro de cada fase, siempre igual que en las anteriores: **`VigoCore` primero con sus tests en
verde, la app después.** Es lo que permite verificar sin simulador, y es la razón declarada en
`ESTADO.md` de que la lógica del mapa viva en `VigoCore`.

Sub-pasos sugeridos para `ESTADO.md`:

- **8.1** `Journey.walkSegments` + `hasDeparted` en `VigoCore` + tests · **8.2** las caminatas
  dibujadas en el mapa · **8.3** actualizar a mano, edad de la respuesta y trazas que no
  parpadean · **8.4** «Ya ha salido» en la fila · **8.5** dispositivo
- **9.1** `scheduledDepartures(stopID:routeID:on:)` + tests (con el caso de madrugada) ·
  **9.2** `DepartureBoard` + tests · **9.3** `serviceDays` en `FeedStatus` ·
  **9.4** `LineTimetableView` y el enlace desde el tramo · **9.5** dispositivo
- **10.1** `egressCandidates` (Pareto de bajada) + tests · **10.2** `dominates` de cuatro ejes +
  corte intercalado a 8 + tests · **10.3** `JourneyOrdering` con los tres criterios + tests ·
  **10.4** `MapNavigationState.ordering` + tests · **10.5** el `Menu` y `UserDefaults`
- **11.1** migración `v3` **completa** (`activeJourney` + `recentSearch`) + `ActiveJourneySnapshot`
  + tests · **11.2** CRUD en `TransitRepository` + tests · **11.3** `staleness` + tests ·
  **11.4** `ActiveJourneyStore` · **11.5** cápsula en `RootView` · **11.6** «He subido» ·
  **11.7** dispositivo
- **12.1** `RecentSearchKey` (dedupKey) + tests · **12.2** CRUD con recorte LRU en la misma
  transacción + tests · **12.3** `RecentSearchesStore` · **12.4** sección en `MapSearchSheet` +
  filtrado de guardados y favoritas · **12.5** dispositivo
- **13.1** `ArrivalAlertPlan` + `ArrivalAlertOptions` + tests (todo en el Mac) ·
  **13.2** `ArrivalAlertScheduler` + permiso «Siempre» · **13.3** enganche con
  `ActiveJourneyStore` · **13.4** UI y texto honesto de degradación · **13.5** dispositivo

---

# §6 — Lo que queda por confirmar

**No queda ninguna.** P1–P10 están cerradas:

- **P1–P8:** rama fusionada antes de empezar (hecho, §Fase 0); permiso «Siempre» concedido;
  caminata final con caminata total de desempate; 8 candidatos; 90 minutos de gracia;
  `UNLocationNotificationTrigger` como camino principal; sin histórico de trayectos; iniciar un
  trayecto no enciende el seguimiento.
- **P9 — tres criterios en el menú**, con «Menos caminata» por defecto. «Llega antes» se queda
  porque es el único que responde a *¿llego a tiempo?* y cuesta una línea de menú (§10.2).
- **P10 — `maxEgressCandidates = 3`.** Si en dispositivo las alternativas de bajada se parecen
  demasiado entre sí, subirlo a 4 es cambiar una constante.

Las fases 8 y 9 no abren preguntas nuevas: las tres decisiones que podrían haberlo sido —recta
discontinua en vez de `MKDirections` (§8.2), nada de replanificación automática (§8.3) y una
línea/una parada/un día en vez de la tabla completa (§9.1)— están tomadas y argumentadas en su
sitio. Si alguna no convence, cambiarla es local a su fase.

---

# §7 — Riesgos

| # | Riesgo | Mitigación |
|---|---|---|
| **R0a** | **La recta discontinua se lee como una promesa de ruta a pie.** Alguien puede seguirla y meterse en una cuesta o en una vía sin acera | Discontinua a propósito, y el texto del tramo ya dice «en línea recta». Si aun así confunde en dispositivo, el arreglo barato no es `MKDirections` sino un pie explícito en el detalle |
| **R0b** | **Actualizar a mano y no ver ningún cambio.** Dentro de la ventana de 20 s del tiempo real y con el mismo minuto de horario, la lista sale idéntica y el gesto parece roto | La hora de cálculo en el pie cambia siempre, así que algo se mueve. No se promete tiempo real fresco en ningún texto |
| **R0c** | **La consulta de un día entero de horarios es más pesada que las que existen hoy.** `scheduledDepartures` está acotada a 3 h y 30 filas por algo | 60–80 filas contra `stopTime` con índice por `stopID`; el mismo orden que la consulta actual sin el `LIMIT`. Medir en dispositivo antes de dar la fase por cerrada, como se midió el `Timetable` en la Fase 3 |
| **R1** | **La Fase 10 ha crecido: ya no es solo ordenar.** Hacer «menos caminata» el criterio por defecto obliga a tocar la generación de candidatos (`egressCandidates`) y el filtro de dominadas — el motor de reconstrucción, no solo la presentación. Es más trabajo y más riesgo del que tenía cuando era el criterio secundario | Está desglosado en 10.1 y 10.2 como pasos con sus propias mutaciones. **Si en algún momento hay que recortar alcance, el recorte correcto es dejar «llega antes» por defecto y «menos caminata» como secundario** — que es el plan barato y honesto. Lo que **no** vale es dejar «menos caminata» por defecto sin el paso 10.1: sería un selector decorativo |
| **R2** | **Tests existentes que van a romperse.** `JourneyAlternativesTests` y `JourneyPlannerTests` asertan cuentas de alternativas, y `maxCandidates` + los candidatos de bajada las cambian | Revisar uno a uno y decidir en cada caso si el número esperado cambia legítimamente o si el test comprobaba el corte. **No ajustar números hasta que vuelvan a pasar**: así es exactamente como se pierde la red de seguridad que este proyecto se ha ganado |
| **R3** | **`selectedAlternative` es un índice sobre una lista que ahora se reordena** | El test de `MapNavigationStateTests` en §10.7 está para eso. Escribir la mutación antes que el código |
| **R4** | **La geovalla es menos fiable de lo que promete**: decenas de segundos de latencia, 100–200 m de incertidumbre, peor en zona densa | Es la razón del preaviso a ≥400 m y de la red de seguridad por tiempo. Aun así, la expectativa realista es «suele avisarte con tiempo», no «siempre», y la UI no debe prometer más |
| **R5** | **El horario teórico se desfasa** y no hay tiempo real a mitad de recorrido | Asumido y documentado. El aviso por tiempo se etiqueta como estimación, coherente con `DataKindBadge` |
| **R6** | **Se rompe una promesa escrita en la UI**: el pie de `MapJourneyLegsView` dice que no hay avisos de bajada | Actualizarlo es parte del trabajo de la Fase 13, no un detalle |
| **R7** | **Migración `v3` sobre datos reales** — ya hay favoritos, lugares y trayectos guardados | Solo **crea** tablas, no toca las existentes. Aun así, probar sobre una copia de la base real antes de instalar |
| **R8** | **Los recientes pueden acabar duplicando visualmente lo que ya hay** en Lugares guardados y Favoritas | Filtrado al leer, nunca al escribir (§12.2), con su test. Y la sección va primera, así que un duplicado se vería enseguida en dispositivo |
| **R9** | **El swipe de borrar un reciente choca con los swipes que ya existen** en las filas de parada: `favouriteActions` ocupa el borde principal y «Guardar» el `trailing` | Los recientes son sus propias filas, no `stopRow`. Decidir allí su propio swipe y comprobarlo en dispositivo |

## Comprobación en dispositivo

**Fase 8**

- [ ] Un trayecto con bus: se ven las dos rectas discontinuas, del origen a la parada y de la bajada al destino
- [ ] Un destino tan cerca que sale `walkOnly`: **ahora se dibuja algo**, que hoy no pasa
- [ ] Con cuatro alternativas, solo la destacada dibuja sus caminatas
- [ ] Dejar pasar la hora de un autobús: la fila dice «Ya ha salido» sin tocar nada
- [ ] Actualizar (botón y tirando hacia abajo): sale el siguiente y el trazado no parpadea
- [ ] El pie dice a qué hora se calculó, y con hora fija de salida no lo dice

**Fase 9**

- [ ] Desde un tramo en bus se llega a los horarios de esa línea en esa parada
- [ ] La lista abre por la próxima salida, no por las 6 de la mañana
- [ ] Una parada con los dos sentidos: dos secciones, no una columna mezclada
- [ ] Una línea nocturna: las salidas de después de medianoche aparecen
- [ ] El selector de día solo ofrece los días que el feed cubre

**Fase 10**

- [ ] Un destino con dos paradas de bajada plausibles: ¿«Menos caminata» ofrece de verdad otra opción, o la misma reordenada?
- [ ] El `Menu` de tres opciones cabe en el header sin partir la fila
- [ ] Cambiar de criterio con una alternativa resaltada: el mapa redibuja la correcta

**Fase 11**

- [ ] Iniciar trayecto, cambiar a Favoritas: la cápsula sigue
- [ ] Matar la app desde el conmutador y reabrir: el trayecto sigue
- [ ] Reiniciar el teléfono: el trayecto sigue
- [ ] Dejar pasar la ventana de gracia: pregunta en vez de desaparecer
- [ ] Forzar un refresco del GTFS con trayecto activo: se sigue dibujando

**Fase 12**

- [ ] Buscar 12 sitios: quedan 10, y el repetido no se duplica
- [ ] Guardar como lugar uno que está en Recientes: desaparece de Recientes
- [ ] Tras el refresco semanal: un reciente de parada sigue funcionando
- [ ] El swipe de borrar no pelea con los que ya existen

**Fase 13**

- [ ] Un trayecto real: ¿llega el preaviso? ¿con cuánta antelación?
- [ ] Con la app terminada: ¿llega igual?
- [ ] Un trayecto que pase por un túnel: qué llega y cuándo
- [ ] Terminar el trayecto a mitad: ¿deja de avisar?
- [ ] Una línea con bucle, si usas alguna: ¿falso positivo? (decide P6 → `CLMonitor`)
