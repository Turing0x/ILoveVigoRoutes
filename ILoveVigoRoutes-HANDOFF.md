# ILoveVigoRoutes — Handoff de implementación

App iOS en SwiftUI para consultar y planificar el transporte público de Vigo (buses Vitrasa + ferry de la ría). **Proyecto personal, de uso estrictamente personal.** No se distribuye, no se publica en la App Store, no se propone a ninguna institución.

---

## 1. Contexto: por qué existe esta app

Vigo no tiene una forma decente de planificar movilidad en el móvil:

- **Google Maps no funciona en la práctica.** En abril de 2026 el Concello anunció que las líneas de Vitrasa ya estaban integradas en Google Maps, con declaraciones del alcalde incluidas. Verificado sobre el terreno: no funciona. La secuencia pública (marzo 2026: "pruebas finales, esperando el ok de Google"; abril 2026: "ya es una realidad") apunta a un anuncio adelantado a la funcionalidad real. Causa técnica exacta no confirmada; la hipótesis más probable es que el feed GTFS municipal esté desactualizado o el alta en Google Transit Partner nunca se completara.
- **Apple Maps tampoco lo cubre.**
- **El ferry de la ría (Vigo–Cangas, Vigo–Moaña, Cíes) no está en ningún planificador.** Sin GTFS, sin anuncios, sin proceso en marcha. Hueco absoluto.
- **La app oficial (App Vigo) es mala en su módulo de transporte:** varios pasos para llegar a la información de una parada, sin horas de paso teóricas accesibles directamente, lenta, viajes de ida/vuelta desordenados, líneas fantasma que ya no existen, y el cálculo de rutas depende de un Moovit embebido en lugar de un motor propio.
- **Moovit** es crowdsourced, mete publicidad y su tiempo real falla en algunas líneas.

El objetivo de ILoveVigoRoutes es resolver esto **para mí**: una app rápida, sin publicidad, centrada en mis paradas y trayectos habituales, que además cubra el ferry.

---

## 2. Fuentes de datos (investigadas, con nivel de confianza)

### 2.1 GTFS estático de Vitrasa — CONFIRMADO, frescura DUDOSA

- Dataset: `https://datos-ckan.vigo.org/dataset/gtfs-vitrasa`
- Descarga directa: `https://datos.vigo.org/data/transporte/gtfs_vigo.zip`
- Licencia: **Open Data Commons Attribution (ODC-BY)** — abierta, permite uso con atribución.
- Formato: ZIP de CSVs GTFS estándar.
- Cadencia declarada: diaria (P1D). **Pero** la metadata del portal mostraba "última actualización 29 enero 2024". Esto es sospechoso y probablemente sea la causa raíz del fallo con Google.

**Acción obligatoria en Fase 0:** descargar el ZIP, comprobar la fecha real de los ficheros, validar el feed y comprobar si `calendar.txt` / `calendar_dates.txt` cubren fechas actuales. Si el feed está caducado, hay que decidir estrategia (ver §5).

### 2.2 Tiempo real de buses (InfoBus / API del Concello) — EXISTE, NO OFICIAL

- Vitrasa opera **InfoBus** por parada: `http://infobus.vitrasa.es/Default.aspx?parada=XXXX` (web, alimentada del SAE).
- **No hay API oficial documentada.** Cita textual del mantenedor de uno de los proyectos comunitarios: *"Vitrasa no da una API oficial que haría esto mucho más fácil e interoperable"*.
- Existe además una API de datos del propio Concello, la que consumen las apps oficiales, explotada por terceros.

**Proyectos comunitarios que ya resolvieron esto y sirven como referencia de implementación (leerlos antes de escribir código de red):**

| Proyecto | Qué es | Utilidad |
|---|---|---|
| `David-Lor/VigoBusAPI` (Apache-2.0) | API intermedia Python/FastAPI + MongoDB que unifica fuentes y devuelve JSON limpio de paradas y llegadas en tiempo real | **La referencia principal.** Documenta qué fuentes existen, cómo se llaman, qué correcciones hacen falta en nombres de paradas y líneas |
| `arielcostas/infobus-bot` (VigoTransitApi) | Wrapper C#/.NET 8 + bot de Telegram, consume la API del Concello | Segunda referencia de endpoints |
| `dpeite/VitrasaTelegramBot` | Bot Telegram Python | Referencia adicional |
| `abdonrd/time-for-vbus-api` | Wrapper del servicio WSDL de Vitrasa a JSON | Muestra que hubo/hay un WSDL |
| `tpgalicia.github.io` | Documentación comunitaria de APIs de transporte gallego por ingeniería inversa, con página específica de Vigo (`/urban/vigo/`) | Documentación de endpoints |

**Acción obligatoria en Fase 0:** clonar/leer `VigoBusAPI` y `infobus-bot` para extraer los endpoints reales y sus formatos de respuesta. No inventar endpoints ni asumir formatos.

### 2.3 Datasets complementarios del Concello — CONFIRMADOS

- `paradas-vitrasa` — JSON/CSV/GeoJSON/SHP/KML
- `lineas-vitrasa` — GeoJSON/SHP/KML (trazados de las líneas)
- Avisos de transporte — JSON/XLS/CSV
- "Navieras - Transporte de Ría" — JSON, describe las navieras pero **no contiene horarios estructurados**

### 2.4 Ferry de la ría — NO EXISTE DATO ESTRUCTURADO

Navieras: **Mar de Ons**, **Piratas de Nabia**, **Rías Gallegas**. Solo publican horarios en web y PDF. Rutas relevantes: Vigo–Cangas, Vigo–Moaña, Vigo–Islas Cíes (estacional, con cupo).

Hay que construir los horarios a mano. Para uso personal es perfectamente asumible: son pocas rutas, con frecuencias regulares (Vigo–Cangas cada ~15-30 min) y variación por temporada (alta/baja), día de semana y festivos.

### 2.5 OpenStreetMap

Las líneas de bus de Vigo están **parcialmente** mapeadas como relaciones (wiki `ES:Vigo/autobuses`, trabajo del usuario michogar). Útil como fuente de contraste para trazados, no como fuente primaria.

### 2.6 GTFS de la Xunta (interurbano) — OPCIONAL, FUTURO

`nap.transportes.gob.es/Files/Detail/1386` — 174.783 viajes, 6.581 rutas, 26.219 paradas, ZIP de 137,16 MB, "Validado correctamente (Sin avisos)", actualizado 8/5/2026. Fuera del alcance inicial; anotado por si algún día interesa cubrir salidas de Vigo hacia el área metropolitana.

---

## 3. Alcance del proyecto

### Dentro de alcance

- App iOS nativa en SwiftUI, uso personal.
- Consulta de paradas de bus con **llegadas en tiempo real**.
- Favoritos de paradas y de trayectos habituales.
- Horarios teóricos por parada y por línea (desde GTFS).
- **Horarios de ferry** de las rutas de la ría.
- Planificador de rutas básico bus + ferry + caminata.
- Widget de pantalla de inicio con las llegadas de la parada favorita.
- Funcionamiento razonable sin conexión para lo estático (GTFS local).

### Fuera de alcance — explícitamente

- Publicación en App Store, TestFlight público o cualquier distribución.
- Cuentas de usuario, backend propio, sincronización en la nube.
- Compra de billetes, integración con PassVigo/TMG.
- Publicidad, analítica, telemetría de cualquier tipo.
- Propuesta institucional, contacto con el Concello, publicación del GTFS corregido en Mobility Database. (Puede reconsiderarse más adelante; hoy no es el objetivo.)
- Soporte multiplataforma (Android, web).
- Accesibilidad exhaustiva más allá de lo que da SwiftUI por defecto + Dynamic Type + VoiceOver básico.

---

## 4. Stack y decisiones técnicas

| Área | Decisión | Motivo |
|---|---|---|
| UI | **SwiftUI**, iOS 17+ mínimo (idealmente 18+) | Decisión del propietario. Permite `@Observable`, SwiftData, mejoras de MapKit |
| Arquitectura | MVVM ligero con `@Observable` (Observation framework), sin frameworks externos de arquitectura | Proyecto de una persona; no necesita ceremonia |
| Persistencia GTFS | **SQLite vía GRDB.swift** | El GTFS son CSVs relacionales con decenas de miles de filas (`stop_times` es grande). SQLite con índices es la herramienta correcta. SwiftData no encaja bien para datos importados en bloque de solo lectura |
| Persistencia de preferencias | SwiftData o simple `Codable` en disco + `@AppStorage` | Favoritos, ajustes: volumen trivial |
| Red | `URLSession` + `async/await`, sin Alamofire | Sin dependencias innecesarias |
| Mapas | **MapKit** (SwiftUI `Map`) | Nativo, gratis, sin claves de API. Suficiente para mostrar paradas y trazados |
| Concurrencia | Swift Concurrency estricto, `Sendable` correcto | Evita problemas al importar GTFS en background |
| Widget | WidgetKit | Llegadas de la parada favorita |
| Atajos | App Intents | "¿Cuándo pasa el bus?" desde Siri/Spotlight |
| Tests | Swift Testing (o XCTest) para el parser GTFS y el motor de rutas | Son las partes con lógica real y susceptibles de romperse en silencio |
| Dependencias | Solo GRDB.swift vía SPM. Añadir más solo con justificación explícita | Mantener el proyecto ligero |

**Sin backend.** La app habla directamente con las fuentes públicas. Esto es viable porque es uso personal (volumen de peticiones ínfimo) y evita mantener infraestructura. Consecuencia: hay que ser respetuoso con las fuentes — cachear agresivamente, no hacer polling salvaje, y aplicar un `User-Agent` identificable.

---

## 5. Estrategia frente al problema de frescura del GTFS

Este es el riesgo técnico número uno del proyecto. Tres escenarios, a resolver en Fase 0 tras verificar:

**Escenario A — el GTFS está actualizado.** Ideal. Importar directamente, con un mecanismo de refresco periódico (comprobar `ETag`/`Last-Modified` del ZIP, reimportar si cambió).

**Escenario B — el GTFS está caducado pero es estructuralmente correcto.** Usarlo para topología (paradas, líneas, trazados, secuencias de paradas) y apoyarse en el tiempo real de InfoBus para los horarios efectivos. Marcar en la UI que los horarios teóricos pueden no ser fiables. Es un compromiso aceptable para uso personal, porque lo que se consulta el 90% del tiempo es "cuándo llega el próximo", no el horario teórico.

**Escenario C — el GTFS está roto o inservible.** Reconstruir la topología desde los datasets `paradas-vitrasa` y `lineas-vitrasa` (GeoJSON), completando secuencias de paradas desde InfoBus o desde OSM. Más trabajo, pero factible.

**Decidir el escenario con datos reales antes de escribir el importador**, y dejar constancia de la decisión en el README del repo.

---

## 6. Plan por fases

Cada fase debe quedar funcional y usable por sí sola. La Fase 1 ya cubre la mayor parte del valor diario.

### Fase 0 — Verificación y cimientos (primero, sin excepción)

1. Descargar `https://datos.vigo.org/data/transporte/gtfs_vigo.zip`. Comprobar: tamaño, fecha de modificación de los ficheros internos, rango de fechas de `calendar.txt` y `calendar_dates.txt`, número de rutas/paradas/viajes.
2. Validar el feed con el **MobilityData GTFS validator** (si está disponible en el entorno) o con validaciones propias mínimas: integridad referencial entre `trips`/`stop_times`/`stops`/`routes`, formatos de hora, servicios activos hoy.
3. Leer el código de `David-Lor/VigoBusAPI` y `arielcostas/infobus-bot` para extraer los endpoints reales de tiempo real y sus formatos de respuesta.
4. Probar esos endpoints con `curl` contra 2-3 paradas conocidas y documentar el formato exacto de respuesta.
5. Recopilar manualmente los horarios actuales de ferry de las tres navieras (Vigo–Cangas, Vigo–Moaña, y Cíes si aplica en temporada).
6. **Escribir un documento `DATA-SOURCES.md` en el repo** con todo lo verificado: endpoints, formatos, frescura del GTFS, escenario elegido de §5, y qué falló o no se pudo verificar.

### Fase 1 — Paradas y tiempo real (el núcleo)

- Importador de GTFS a SQLite (en background, con progreso, idempotente).
- Modelo de datos: `stops`, `routes`, `trips`, `stop_times`, `calendar`, `calendar_dates`, `shapes`.
- Pantalla **Cercanas**: paradas próximas a la ubicación actual, ordenadas por distancia, con las líneas que pasan por cada una.
- Pantalla **Detalle de parada**: llegadas en tiempo real (minutos restantes, línea, destino), autorrefresco cada 30 s mientras la pantalla está visible, pull-to-refresh, y horarios teóricos como respaldo cuando no hay tiempo real.
- **Favoritos**: marcar paradas, acceso inmediato desde el arranque.
- Búsqueda de paradas por nombre y por número.
- Mapa con paradas.
- Manejo de errores explícito y honesto: si el tiempo real falla, decirlo, no mostrar horarios teóricos disfrazados de tiempo real.

### Fase 2 — Ferry de la ría

- Modelo de horarios de ferry como recurso local versionado (JSON en el bundle, editable a mano).
- Estructura: naviera, ruta, sentido, lista de salidas por tipo de día (laborable / sábado / domingo-festivo), y periodo de vigencia (temporada alta/baja, con fechas).
- Pantalla **Ferry**: próximas salidas desde Vigo, Cangas y Moaña, con cuenta atrás.
- Aviso visible en la UI de que los horarios de ferry son de mantenimiento manual y su fecha de última actualización.
- Alerta cuando los datos de ferry lleven más de X meses sin actualizar.

### Fase 3 — Planificador de rutas

- Motor de planificación **en el dispositivo**, sobre el GTFS en SQLite: implementar **RAPTOR** o **CSA (Connection Scan Algorithm)**. Son algoritmos bien documentados y adecuados para una red del tamaño de Vigo (~45 líneas, ~1.100 paradas).
- Multimodal simple: caminar → bus → (transbordo) → bus/ferry → caminar. Radio de caminata configurable (por defecto 800 m).
- Incorporar el ferry como otro conjunto de conexiones en el mismo grafo temporal.
- Resultado: 2-3 alternativas con hora de salida, transbordos, duración total y tiempo de caminata.
- **No usar OpenTripPlanner ni ningún servidor de routing.** Para esta escala y uso personal, un motor propio en Swift es más simple que mantener un servicio.

### Fase 4 — Pulido y comodidades

- Widget de WidgetKit: llegadas de la parada favorita.
- App Intents / Atajos de Siri.
- Trayectos guardados ("casa → trabajo") con un toque.
- Modo oscuro correcto, Dynamic Type, VoiceOver en los elementos principales.
- Refresco automático del GTFS en segundo plano cuando cambie el ZIP remoto.

---

## 7. Criterios de aceptación

Fase 1 se considera terminada cuando:
- La app importa el GTFS completo sin bloquear la UI y sin duplicar datos al reimportar.
- Desde el arranque en frío, ver las llegadas en tiempo real de una parada favorita toma **un toque o ninguno**.
- La búsqueda de una parada por nombre devuelve resultados en menos de 100 ms.
- Si la fuente de tiempo real está caída, la app lo indica claramente y sigue mostrando horarios teóricos etiquetados como tales.
- Funciona sin conexión para todo lo estático.

Fase 3 se considera terminada cuando:
- Un trayecto conocido (por ejemplo, un origen y destino que el propietario hace habitualmente) devuelve una ruta correcta y comparable a la realidad.
- El planificador responde en menos de 1 segundo en un iPhone reciente.

---

## 8. Restricciones y principios

- **Uso personal.** No distribuir. Firmar con la cuenta de desarrollador personal.
- **Cero telemetría, cero anuncios, cero cuentas.**
- **Ser buen ciudadano con las fuentes:** cachear, no hacer polling agresivo, respetar `Cache-Control`, usar un `User-Agent` identificable, y no pegar peticiones a InfoBus en bucle en segundo plano.
- **Atribución:** el GTFS es ODC-BY. Incluir una pantalla de "Fuentes de datos" con la atribución al Concello de Vigo y a los proyectos comunitarios cuya documentación de endpoints se haya aprovechado.
- **Honestidad en la UI:** nunca presentar un dato teórico o cacheado como si fuera tiempo real. Si algo no se sabe, se dice.
- **El código debe sobrevivir a que las fuentes cambien:** aislar toda la capa de red en un módulo con protocolos, de modo que si InfoBus cambia de formato solo haya que tocar un sitio.

---

## 9. Huecos de información conocidos

Estos puntos no están verificados y hay que resolverlos durante la implementación, no asumirlos:

1. Frescura y validez real del GTFS de Vitrasa (metadata sugería enero 2024 pese a cadencia diaria declarada).
2. Endpoints exactos y formato de respuesta del tiempo real (InfoBus / API del Concello). Deducir de los repos comunitarios y verificar con `curl`.
3. Si el WSDL de Vitrasa (referenciado por `abdonrd/time-for-vbus-api`) sigue vivo o está muerto.
4. Estabilidad de las URLs del portal de datos abiertos (`datos.vigo.org` vs `datos-ckan.vigo.org`).
5. Cobertura real del GTFS: ¿incluye `shapes.txt` con los trazados, o solo paradas y secuencias?
6. Horarios de ferry vigentes de las tres navieras, y cómo estructurar la variación estacional.
7. Cifras de referencia de la red (127 buses / 45 líneas según Wikipedia abril 2026; el propio Concello menciona 116 buses en su web). Contrastar con lo que diga el GTFS.
