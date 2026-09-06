# Auditoría del motor de búsquedas

> **Alcance.** Todo lo que ocurre desde que el usuario toca la barra de búsqueda del mapa hasta
> que un resultado se convierte en un `MapPlace`: `TextNormalization`, `TransitRepository`
> (`searchStops`, `nearbyStops`, `routesWithService`), los índices de `AppDatabase`, `MapPlace`,
> y en la app `MapSearchSheet`, `AddressSearch`, `AddressSearchModel`,
> `MapKitAddressSearchService`, `MapPlaceResolver`, `MapPointPickerView`, `LocationProvider` y
> los llamantes de la hoja.
>
> **Fuera de alcance:** RAPTOR, tiempo real, el importador salvo el punto donde calcula
> `searchName`, el dibujo del mapa, Favoritas, el trayecto activo y la Fase 13. Lo que asomó
> fuera de alcance está en el §7, en dos líneas.
>
> **Motivo.** El motor nació de fusionar dos buscadores divergentes (Fase 7) y nunca se ha
> auditado como una pieza entera; la Fase 12 («búsquedas recientes») está planificada encima de
> él sobre supuestos que conviene contrastar antes de escribir código.
>
> Fecha: 2026-09-06. Ningún fichero de código ni de tests fue modificado para producir este
> informe.

---

## Cómo se ha verificado

- `swift test` en `VigoCore/`: **321 tests en verde, 3,6 s**. Suite de partida sana.
- Feed real importado a una base de disco desde `/private/tmp/gtfs_vigo.zip` mediante un
  ejecutable desechable fuera del repo (`GTFSParser` + `GTFSImporter` reales):
  **1154 paradas, 59 rutas, 45 con servicio, 3801 viajes, 137 456 `stop_times`**.
- Batería de ~50 consultas ejecutada contra **`TransitRepository.searchStops` de verdad**, no
  contra una reimplementación.
- `EXPLAIN QUERY PLAN` de las cinco consultas del buscador contra esa base.
- **Diez mutaciones deliberadas** aplicadas sobre una copia de `VigoCore` fuera del repo, cada
  una con `swift test` completo. Resultados en el eje H.
- Todo lo que necesita simulador, dispositivo o los servidores de Apple va marcado
  **«no verificado — razonamiento»** y con la confianza bajada.

---

## 1. Resumen ejecutivo

El motor está **estructuralmente bien y semánticamente flojo**. La arquitectura aguanta: un
solo `Purpose`, la lógica de plegado en `VigoCore`, la privacidad de la ubicación respetada en
todos los caminos que he podido seguir, y la decisión de resolver direcciones solo al tocar
está cumplida. Lo que falla es la **calidad del emparejamiento** —consultas perfectamente
razonables devuelven cero— y una **hoja que miente en varios estados**.

Tres cosas primero:

1. **«Elegir en el mapa» no geocodifica.** La ruta accesible que la Fase 7 añadió a propósito
   para VoiceOver produce siempre «Punto en el mapa», mientras la pulsación larga del mapa
   —inaccesible— sí resuelve la calle. El hueco de accesibilidad que la Fase 7 dice haber
   cerrado está cerrado en *alcance* y abierto en *calidad* (H-33).
2. **El emparejamiento de paradas es contiguo y sensible a la puntuación.** «praza america»,
   «avda florida», «hospital povisa» y «urzaiz principe» devuelven **cero** contra el feed real
   (H-09, H-10). Es lo que más se nota usando la app y lo más barato de arreglar: no hace falta
   FTS5.
3. **`pick(_:)` ya no es un embudo único** y la tabla `completions` se corrompe con los
   refinamientos del completer (H-34, H-13). El primero bloquea la Fase 12 tal y como está
   escrita; el segundo produce un error visible al usuario hoy.

Además, los comodines `%` y `_` que teclee el usuario llegan crudos al `LIKE` (H-01), y cuatro
comportamientos del repositorio sobreviven a mutaciones deliberadas, es decir, **no están
cubiertos** (H-40 a H-43).

---

## 2. Tabla de hallazgos

| # | Título | Sev. | Conf. | Categoría | Fichero |
|---|---|---|---|---|---|
| H-33 | «Elegir en el mapa» nunca geocodifica el punto elegido | alta | alta | invariante | MapSearchSheet.swift:107 |
| H-34 | Los trayectos guardados no pasan por `pick(_:)` | alta | alta | invariante | MapSearchSheet.swift:198 |
| H-09 | Términos no contiguos o en otro orden no encuentran nada | alta | alta | corrección | TransitRepository.swift:210 |
| H-10 | La puntuación del nombre no se pliega | alta | alta | corrección | TextNormalization.swift:9 |
| H-13 | Un refinamiento del completer invalida las sugerencias visibles | alta | media | concurrencia | MapKitAddressSearchService.swift:99 |
| H-01 | `%` y `_` del usuario actúan como comodines de `LIKE` | alta | alta | bug | TransitRepository.swift:211 |
| H-02 | `exact + prefix` supera `limit` en la rama numérica | media | alta | bug | TransitRepository.swift:206 |
| H-03 | Un cero a la izquierda rompe la rama de prefijo numérico | media | alta | bug | TransitRepository.swift:203 |
| H-04 | La rama numérica no ordena y anula la búsqueda por nombre | media | alta | UX | TransitRepository.swift:200 |
| H-07 | `stop_searchName` no acelera el `LIKE`: escaneo completo | media | alta | rendimiento | AppDatabase.swift:49 |
| H-08 | La consulta a SQLite corre en el main actor por pulsación | media | alta | rendimiento | MapSearchSheet.swift:70 |
| H-11 | Ninguna tolerancia a erratas de una letra | media | alta | UX | TransitRepository.swift:210 |
| H-15 | `onCancel` puede resumir la continuación de la consulta siguiente | media | media | concurrencia | MapKitAddressSearchService.swift:81 |
| H-16 | Sin timeout: `isSearching` se queda pegado para siempre | media | media | concurrencia | AddressSearchModel.swift:48 |
| H-17 | Un `queryFragment` repetido puede dejar la continuación colgada | media | baja | concurrencia | MapKitAddressSearchService.swift:76 |
| H-18 | Toque y deslizar «Guardar» compiten por una sola resolución | media | media | concurrencia | MapSearchSheet.swift:369 |
| H-22 | Con 1–2 caracteres afirma «No hay resultados» sin haber buscado | media | alta | UX | MapSearchSheet.swift:308 |
| H-24 | 45 líneas no interactivas dominan el estado vacío | media | alta | UX | MapSearchSheet.swift:241 |
| H-25 | `matchingLines` con `contains`: «a» devuelve 44 de 45 líneas | media | alta | UX | MapSearchSheet.swift:263 |
| H-27 | `stopRow` con `.buttonStyle(.plain)` y sin `contentShape` | media | baja | accesibilidad | MapSearchSheet.swift:327 |
| H-28 | Base sin importar y feed caducado son invisibles aquí | media | alta | UX | MapSearchSheet.swift:56 |
| H-30 | Dos `CLLocationManager` vivos a la vez sobre el mapa | media | alta | rendimiento | MapSearchSheet.swift:50 |
| H-36 | `EndpointPickerSheet` es un segundo selector delante del único | media | alta | deuda | SavedJourneyEditorView.swift:146 |
| H-38 | `MapPlace.savedEndpoint` etiqueta `.address` un extremo de parada | media | alta | corrección | MapPlace.swift:135 |
| H-40 | El orden prefijo-antes-que-contenido no está cubierto | media | alta | testabilidad | RepositoryTests.swift:136 |
| H-41 | La rama de prefijo numérico no está cubierta | media | alta | testabilidad | RepositoryTests.swift:146 |
| H-42 | `limit` no está cubierto en ninguna rama | media | alta | testabilidad | RepositoryTests.swift:136 |
| H-43 | El filtro exacto de radio de `nearbyStops` no está cubierto | media | alta | testabilidad | RepositoryTests.swift:163 |
| H-44 | «Consulta → secciones y su orden» es hoy inverificable | media | alta | testabilidad | MapSearchSheet.swift:269 |
| H-45 | `matchingLines` es lógica de decisión atrapada en la vista | media | alta | invariante | MapSearchSheet.swift:260 |
| H-46 | §12.4 del plan enumera seis llamantes de `pick` que no coinciden | media | alta | deuda | PLAN-FASES-8-13.md:851 |
| H-47 | Todos los pines recientes se llamarían «Punto en el mapa» | media | alta | UX | PLAN-FASES-8-13.md:789 |
| H-14 | El comentario «later refinements are dropped» ya no es cierto | media | alta | deuda | MapKitAddressSearchService.swift:60 |
| H-05 | «numérico» acepta espacios interiores: «69 30» == «6930» | baja | alta | UX | TransitRepository.swift:197 |
| H-06 | `Int(digits)` desborda en silencio y cae a búsqueda por nombre | baja | alta | bug | TransitRepository.swift:200 |
| H-19 | `AddressSuggestion.id` se regenera en cada emisión | baja | media | rendimiento | MapKitAddressSearchService.swift:102 |
| H-20 | `failed` sobrevive a la consulta siguiente | baja | alta | UX | AddressSearchModel.swift:68 |
| H-21 | La sección «Direcciones» se dibuja siempre, aunque esté vacía | baja | alta | UX | MapSearchSheet.swift:283 |
| H-23 | El texto de ayuda del estado vacío ignora dos secciones | baja | alta | UX | MapSearchSheet.swift:247 |
| H-26 | `matchingLines` se recalcula dos veces por `body` | baja | alta | rendimiento | MapSearchSheet.swift:277 |
| H-29 | Permiso denegado: «Cerca de ti» desaparece sin explicación | baja | alta | UX | MapSearchSheet.swift:235 |
| H-31 | Una pulsación anterior a `.task` se pierde para las direcciones | baja | media | bug | MapSearchSheet.swift:74 |
| H-32 | El picker anidado cambia la hoja externa mientras se cierra | baja | baja | UX | MapSearchSheet.swift:106 |
| H-35 | El sheet reimplementa `MapPlace.savedPlace(_:)` | baja | alta | deuda | MapSearchSheet.swift:220 |
| H-37 | `SavedPlaceEditorView.input(for:)` duplica `savedEndpointInput` | baja | alta | deuda | SavedPlaceEditorView.swift:191 |
| H-48 | El redondeo a ~11 m vive en un `private var` de la vista | baja | alta | deuda | MapSearchSheet.swift:175 |
| H-39 | `matchingLines` no usa `normalizedLineName` | nit | alta | deuda | MapSearchSheet.swift:264 |
| H-12 | El comentario del coste cita 1149 filas y 0,2 ms | nit | alta | deuda | MapSearchSheet.swift:10 |

---

## 3. Hallazgos en detalle

### H-01 · `%` y `_` del usuario actúan como comodines de `LIKE`
**`VigoCore/Sources/VigoCore/Persistence/TransitRepository.swift:211`** · **Severidad:** alta ·
**Confianza:** alta · **Categoría:** bug

**Qué pasa.** El texto que teclea el usuario se interpola directamente en el patrón de `LIKE`
sin escapar `%` ni `_` y sin cláusula `ESCAPE`. Un `%` suelto casa con todas las paradas.

**Cómo reproducirlo.** Contra el feed real, verificado:

```
searchStops("%")        -> 50 resultados (el limit)   esperado: 0
searchStops("_")        -> 50 resultados               esperado: 0
searchStops("%a%")      -> 50 resultados               esperado: 0
searchStops("100%")     ->  4 resultados               esperado: 0
searchStops("praza_de") -> 12 resultados               esperado: 0
```

`praza_de` casando con «praza de américa» es el caso claro: el `_` está haciendo de comodín de
un carácter.

**Por qué pasa.** `"\(folded)%"`, `"%\(folded)%"` y `"\(folded)%"` en las líneas 211, 215 y 203
construyen el patrón por interpolación. GRDB parametriza el **valor**, no el **patrón**: la
cadena llega entera como patrón de `LIKE`, donde `%` y `_` son metacaracteres.

**Cómo lo arreglaría.** Escapar en el plegado, un único sitio, y declarar `ESCAPE`:

```swift
// en TextNormalization
public static func likePattern(_ folded: String) -> String {
    folded.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "%",  with: "\\%")
          .replacingOccurrences(of: "_",  with: "\\_")
}
// y en la consulta
.filter(sql: "searchName LIKE ? ESCAPE '\\'", arguments: ["\(likePattern(folded))%"])
```

**Cómo lo verificaría.** `RepositoryTests.searchEscapesLikeWildcards`, en
`VigoCore/Tests/VigoCoreTests/RepositoryTests.swift`: `#expect(try repository.searchStops("%").isEmpty)`
y `#expect(try repository.searchStops("praza_de").isEmpty)`. Mutación que debe tumbarlo:
quitar el `ESCAPE` o dejar de escapar `_`.

---

### H-02 · `exact + prefix` supera `limit` en la rama numérica
**`TransitRepository.swift:206`** · **Severidad:** media · **Confianza:** alta · **Categoría:** bug

**Qué pasa.** `return exact + prefix` no recorta. `prefix` está limitado a `limit`, pero `exact`
se suma encima.

**Cómo reproducirlo.** Verificado contra el feed real, donde existe la parada de código `20` y
hay 139 códigos que empiezan por `20`:

```
searchStops("20")            -> 51 filas   (limit por defecto 50)
searchStops("20", limit: 10) -> 11 filas   (limit 10)
```

**Por qué pasa.** Línea 206: `if !exact.isEmpty || !prefix.isEmpty { return exact + prefix }`.
La rama por nombre sí recorta (línea 217, `.prefix(limit)`); esta no.

**Cómo lo arreglaría.** `return Array((exact + prefix).prefix(limit))`.

**Cómo lo verificaría.** `RepositoryTests.numericSearchRespectsLimit`:
`#expect(try repository.searchStops("20", limit: 3).count <= 3)`. Mutación: devolver
`exact + prefix` sin recortar. **Nota:** el fixture actual (4 paradas) no tiene códigos
suficientes; el test necesita insertar unas cuantas paradas sintéticas o vivir en
`RealFeedIntegrationTests`.

---

### H-03 · Un cero a la izquierda rompe la rama de prefijo numérico
**`TransitRepository.swift:203`** · **Severidad:** media · **Confianza:** alta · **Categoría:** bug

**Qué pasa.** Con ceros a la izquierda, la comparación exacta y la de prefijo dejan de estar de
acuerdo, y el resultado depende de cuántos dígitos se hayan tecleado.

**Cómo reproducirlo.** Verificado:

```
searchStops("693")   -> 1  (Praza de América 1, código 6930)
searchStops("0693")  -> 0     <-- esperado: lo mismo que "693"
searchStops("06930") -> 1  (funciona, por casualidad)
```

**Por qué pasa.** `code = Int(digits)` normaliza `"0693"` a `693` y busca la exacta —que no
existe—, pero el prefijo usa `digits` sin normalizar: `CAST(vitrasaCode AS TEXT) LIKE '0693%'`
no casa con nada porque ningún código se almacena con cero inicial. Con `"06930"` la comparación
exacta salva la papeleta. Con cuatro dígitos, ninguna de las dos casa y se cae a la búsqueda por
nombre, que tampoco encuentra nada.

**Cómo lo arreglaría.** Usar la representación canónica en las dos ramas:

```swift
if isNumeric, let code = Int(digits) {
    let canonical = String(code)
    let prefix = try Stop.filter(
        sql: "CAST(vitrasaCode AS TEXT) LIKE ? ESCAPE '\\' AND vitrasaCode <> ?",
        arguments: ["\(canonical)%", code]).limit(limit).fetchAll(db)
```

**Cómo lo verificaría.** `RepositoryTests.numericSearchIgnoresLeadingZeros`:
`#expect(try repository.searchStops("0693").map(\.id) == repository.searchStops("693").map(\.id))`.
Mutación: volver a `digits` en el patrón.

---

### H-04 · La rama numérica no ordena, y anula por completo la búsqueda por nombre
**`TransitRepository.swift:200-207`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** UX

**Qué pasa.** Cuando la consulta es numérica y hay algún acierto de código, se devuelven
**solo** aciertos de código, en **orden de tabla** (sin `ORDER BY`), y nunca se consultan los
nombres. Teclear `1` devuelve 50 paradas cuyo código empieza por 1, en orden arbitrario, y
ninguna cuyo nombre contenga «1».

**Cómo reproducirlo.** Verificado: `searchStops("1")` → 50 filas, encabezadas por «Rúa de Santo
Amaro (Praza de España)», «Avda. das Camelias 136», «Rúa do Conde de Torrecedeira 123». Ninguna
tiene un «1» visible: son códigos `1xxx`. Quien teclea `1` buscando «Rúa de Barcelona 18» o la
línea 1 no ve nada útil.

**Por qué pasa.** Las dos consultas de la rama numérica (líneas 201 y 203) no llevan `.order`, y
el `return` de la línea 206 corta el flujo antes de la búsqueda por nombre.

**Cómo lo arreglaría.** Dos cambios pequeños: ordenar el prefijo por `vitrasaCode` ascendente, y
**fusionar** en vez de cortar — código exacto primero, luego prefijo de código, luego nombres,
recortando al final. Un número corto (1–2 dígitos) es tan probablemente un número de portal como
un código de parada.

**Cómo lo verificaría.** `RepositoryTests.numericSearchAlsoMatchesNames`:
con el fixture, `searchStops("1")` debe contener alguna parada cuyo `searchName` contenga «1».
Mutación: volver al `return` temprano.

---

### H-05 · «Numérico» acepta espacios interiores
**`TransitRepository.swift:197`** · **Severidad:** baja · **Confianza:** alta · **Categoría:** UX

**Qué pasa.** `isNumeric` admite espacios, y `digits` los elimina, así que `"69 30"` es
exactamente `"6930"`. Verificado: `searchStops("69 30")` → 1 resultado, la parada 6930.

**Por qué pasa.** `folded.allSatisfy { $0.isNumber || $0.isWhitespace }` combinado con
`folded.filter(\.isNumber)`.

**Cómo lo arreglaría.** Es plausiblemente útil (números leídos en voz alta, teclado numérico).
Lo que falta es que esté **escrito**: el comentario de la línea 190 no lo menciona. Documentarlo
o restringirlo a un único bloque de dígitos.

**Cómo lo verificaría.** `RepositoryTests.numericSearchIgnoresInnerSpaces`, con la decisión que se
tome; hoy no hay ningún test que fije este comportamiento en un sentido ni en otro.

---

### H-06 · `Int(digits)` desborda en silencio
**`TransitRepository.swift:200`** · **Severidad:** baja · **Confianza:** alta · **Categoría:** bug

**Qué pasa.** Una consulta de 20 dígitos hace que `Int(digits)` devuelva `nil`, la rama numérica
se salta entera y se cae a la búsqueda por nombre, que no encuentra nada. No hay crash —
verificado: `searchStops("99999999999999999999")` → 0 resultados— pero el prefijo de código, que
sí habría podido responder, no se llega a probar.

**Cómo lo arreglaría.** Ejecutar la rama de prefijo aunque `Int(digits)` falle: el `LIKE` sobre
`CAST(vitrasaCode AS TEXT)` no necesita el entero. Solo la comparación exacta lo necesita.

**Cómo lo verificaría.** `RepositoryTests.numericSearchSurvivesOverflow`, comprobando que un
prefijo largo pero válido (`"6930000000000000000000"`) devuelve vacío sin lanzar, y que el
prefijo corto sigue funcionando.

---

### H-07 · El índice `stop_searchName` no acelera el `LIKE`: escaneo completo
**`AppDatabase.swift:49`** · **Severidad:** media · **Confianza:** alta · **Categoría:** rendimiento

**Qué pasa.** El índice existe y se usa, pero como **escaneo**, no como búsqueda por rango.
`EXPLAIN QUERY PLAN` contra la base real (SQLite 3.51.0):

```
SELECT * FROM stop WHERE searchName LIKE 'urzaiz%' ORDER BY searchName LIMIT 50;
`--SCAN stop USING INDEX stop_searchName
```

**Por qué pasa.** La optimización de `LIKE` de SQLite exige que la columna esté indexada con
colación `NOCASE` cuando `case_sensitive_like` está desactivado (que es el valor por defecto).
`stop_searchName` usa `BINARY`, así que la optimización queda inhabilitada. Comprobado en los
dos sentidos contra la misma base:

```
PRAGMA case_sensitive_like=ON;   -> SEARCH stop USING INDEX stop_searchName (searchName>? AND searchName<?)
CREATE INDEX … ON stop(searchName COLLATE NOCASE);
                                 -> SEARCH stop USING INDEX stop_searchName_nocase (searchName>? AND searchName<?)
```

**Cómo lo arreglaría.** Migración `v4` con
`CREATE INDEX stop_searchName ON stop(searchName COLLATE NOCASE)`, o dejarlo tal cual y
**corregir el comentario**: hoy el lector supone que el índice sirve para el prefijo. A 1154
filas el coste medido es 0,27–0,58 ms en un Mac, así que esto es sobre todo una nota de
corrección documental — salvo que la reescritura del eje B (H-09) haga la consulta más cara,
momento en que sí importa.

**Cómo lo verificaría.** Un test en `RepositoryTests` que ejecute
`EXPLAIN QUERY PLAN` y afirme `SEARCH` en vez de `SCAN`. Mutación: volver a un índice `BINARY`.

---

### H-08 · La consulta a SQLite corre en el main actor por pulsación
**`MapSearchSheet.swift:70-75`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** rendimiento

**Qué pasa.** `.onChange(of: query)` llama a `environment.repository.searchStops(query)`
**síncronamente en el main actor**, en cada pulsación. Todo lo demás en esta hoja —líneas,
cercanía— se saca del main actor con `Task.detached`; esto no.

**Cómo reproducirlo.** Medido contra el feed real, en un Mac:
`searchStops("a")` 0,584 ms, `"urzaiz"` 0,286 ms, `"20"` 0,311 ms. En un iPhone hay que contar
un factor de tres a cinco. Escribiendo rápido, cada carácter cuesta una lectura síncrona a
SQLite antes de que el `body` pueda redibujarse.

**Por qué pasa.** La línea 71-73 es una expresión síncrona dentro del `onChange`.

**Cómo lo arreglaría.** El mismo patrón que ya usan `lines` y `nearby`, con `.task(id: query)`:

```swift
.task(id: query) {
    guard !query.isEmpty else { results = []; return }
    let repository = environment.repository, q = query
    results = await Task.detached(priority: .userInitiated) {
        (try? repository.searchStops(q)) ?? []
    }.value
}
```

Esto además da cancelación gratis: hoy no hay ninguna.

**Cómo lo verificaría.** No es testeable sin simulador; se comprueba en dispositivo escribiendo
rápido en una parada de nombre largo. Lo que **sí** se puede testear es el tipo puro de H-44.

---

### H-09 · Términos no contiguos o en otro orden no encuentran nada
**`TransitRepository.swift:210-217`** · **Severidad:** alta · **Confianza:** alta ·
**Categoría:** corrección

**Qué pasa.** El emparejamiento es una subcadena literal. Cualquier consulta que no sea un
fragmento contiguo del nombre plegado devuelve cero.

**Cómo reproducirlo.** Batería ejecutada contra el feed real:

| Consulta | Resultados | Esperado |
|---|---|---|
| `praza de america` | 3 | 3 |
| `praza america` | **0** | 3 |
| `america praza` | **0** | 3 |
| `hospital povisa` | **0** | 1 (Rúa de Barcelona Hospital Ribera Povisa) |
| `urzaiz principe` | **0** | 1 (Rúa de Urzáiz - Príncipe) |
| `granvia` | **0** | 16 |

Las stop words gallegas (`de`, `da`, `do`) son el detonante habitual: casi todos los nombres del
feed las llevan y casi nadie las teclea.

**Por qué pasa.** Un único `LIKE '%folded%'` con el texto entero. No hay tokenización.

**Cómo lo arreglaría.** **No hace falta FTS5 ni trigramas sobre 1154 filas** — sería
sobreingeniería, y además FTS5 obliga a mantener una tabla espejo que el importador tendría que
reconstruir en cada refresco. Basta con dividir la consulta en términos y exigirlos todos:

```swift
let terms = folded.split(separator: " ").map(String.init)
let clause = terms.map { _ in "searchName LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
let args   = terms.map { "%\(likePattern($0))%" }
```

y puntuar después en Swift para el orden (prefijo del nombre > prefijo de palabra > contenido).
Medido: la consulta actual son 0,3 ms; tres `LIKE` encadenados sobre 1154 filas siguen siendo
sub-milisegundo, y H-08 la saca del main actor de todas formas.

**Cómo lo verificaría.** `RepositoryTests.searchMatchesTermsInAnyOrder`, con el fixture ampliado
o directamente en `RealFeedIntegrationTests`:
`#expect(!(try repository.searchStops("america praza")).isEmpty)`.
Mutación que debe tumbarlo: volver a un único `LIKE` con la consulta entera.

---

### H-10 · La puntuación del nombre no se pliega
**`TextNormalization.swift:9-13`** · **Severidad:** alta · **Confianza:** alta ·
**Categoría:** corrección

**Qué pasa.** `searchFolded` quita acentos, baja a minúsculas y colapsa espacios, pero **deja
la puntuación**. El feed está lleno de abreviaturas con punto, y el usuario no las teclea.

**Cómo reproducirlo.** Verificado. `searchFolded("Avda. da Florida  117")` → `avda. da florida 117`.

| Consulta | Resultados |
|---|---|
| `florida` | 14 |
| `avda. florida` | **0** |
| `avda florida` | **0** |
| `av florida` | **0** |

Y `searchFolded("Av. García Barbón")` → `av. garcia barbon`: el punto sobrevive. Lo mismo con los
guiones (`rua de urzaiz - principe`) y las comillas
(`avda. beiramar "porto pesqueiro berbes"`).

**Nota sobre la «ñ»:** **no es un problema.** Comprobado sobre las 1154 filas reales,
`searchName` no contiene ninguna `ñ` — el plegado con `es_ES` la convierte en `n`— y la consulta
del usuario pasa por la misma función, así que «porriño» y «porrino» devuelven los mismos 5
resultados. `casás`/`casas`, `coruña`/`coruna` y `españa`/`espana` también coinciden. Verificado.

**Cómo lo arreglaría.** Añadir un paso al plegado que sustituya la puntuación por espacio antes
de colapsar. Cuidado: **cambia `searchName`, que se calcula en el import**
(`GTFSParser.swift:137`), así que hay que forzar una reimportación o migrar la columna. Y hay que
mantener `searchFolded` como **única** función, porque `MapSearchSheet.matchingLines` y el
`dedupKey` de la Fase 12 también la usan.

```swift
let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
return String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
```

**Cómo lo verificaría.** `GTFSParserTests.foldedNameDropsPunctuation`:
`#expect(TextNormalization.searchFolded("Avda. da Florida") == "avda da florida")`, más un test
de `searchStops("avda florida")` no vacío. Mutación: quitar el paso de puntuación — hoy
sobrevive porque nadie lo comprueba.

---

### H-11 · Ninguna tolerancia a erratas de una letra
**`TransitRepository.swift:210`** · **Severidad:** media · **Confianza:** alta · **Categoría:** UX

**Qué pasa.** Verificado: `corua` → 0 (frente a `coruna` → 6), `torrecedera` → 0 y
`torecedeira` → 0 (frente a `torrecedeira` → 9).

**Cómo lo arreglaría.** **No lo arreglaría todavía.** Distancia de edición sobre 1154 nombres es
perfectamente asumible (un Levenshtein acotado a distancia 1 sobre los términos, en Swift, tras
el filtro `LIKE`), pero solo tiene sentido **después** de H-09 y H-10: la mayoría de los «fallos
por errata» que se notan usando la app son en realidad fallos de orden de palabras o de
puntuación, y arreglarlos primero reduce mucho la superficie. Dejarlo anotado y medir de nuevo.

**Cómo lo verificaría.** Si se implementa: `RepositoryTests.searchToleratesOneTypo` con
`searchStops("torrecedera")` no vacío, y —crucialmente— un test negativo que impida que la
tolerancia se coma la precisión (`searchStops("coia")` no debe devolver «Coruña»).

---

### H-12 · El comentario de cabecera cita cifras que ya no cuadran
**`MapSearchSheet.swift:10-11`** · **Severidad:** nit · **Confianza:** alta · **Categoría:** deuda

«0,2 ms against SQLite over 1149 rows». El feed descargado hoy tiene **1154** paradas, y la
medición contra él da 0,27–0,58 ms en un Mac. El orden de magnitud es correcto; la cifra
concreta invita a creer que el coste está medido en dispositivo, y no lo está. Sugerencia:
citar el orden de magnitud y no el número.

---

### H-13 · Un refinamiento del completer invalida las sugerencias que se están viendo
**`MapKitAddressSearchService.swift:99-107`** · **Severidad:** alta · **Confianza:** media ·
**Categoría:** concurrencia · **(no verificado — razonamiento: necesita los servidores de Apple)**

**Qué pasa.** `MKLocalSearchCompleter` emite varias veces por fragmento. La primera emisión
resume la continuación y la vista pinta esas sugerencias. Las emisiones siguientes **vuelven a
entrar** en `completeResults()`, generan UUID nuevos y **sustituyen la tabla `completions`
entera**. `resumePending` no hace nada (ya no hay continuación), así que la lista visible se
queda con los tokens viejos, que ya no están en la tabla.

**Cómo reproducirlo.** Teclear «Praza de Amé», esperar a que salgan sugerencias, esperar un
segundo más sin tocar nada, y tocar una fila. Esperado: la ficha del lugar. Real:
`completions[suggestion.id]` es `nil`, `resolve` lanza `.notFound`, `AddressSearchModel` pone
`failed = true` y la hoja muestra «No he podido buscar direcciones ahora mismo.» — un error que
no describe lo que ha pasado.

**Por qué pasa.** Líneas 102-103: `completions = Dictionary(uniqueKeysWithValues: tokened)`
sustituye, no acumula, y se ejecuta en **cada** `completerDidUpdateResults`, esté o no pendiente
una continuación.

**Cómo lo arreglaría.** Solo tocar la tabla cuando efectivamente se está resumiendo:

```swift
private func completeResults() {
    guard pending != nil else { return }   // refinamiento tardío: se descarta de verdad
    let tokened = completer.results.map { (UUID(), $0) }
    completions = Dictionary(uniqueKeysWithValues: tokened)
    resumePending(with: tokened.map { AddressSuggestion(id: $0.0, title: $0.1.title, subtitle: $0.1.subtitle) })
}
```

Con esto el comentario de la línea 60 («later refinements are dropped») vuelve a ser cierto —
véase H-14.

**Cómo lo verificaría.** No es testeable a través del seam actual, porque el bug vive **por
debajo** de `AddressSearching`. Es el argumento más fuerte para el corte que propone H-44:
extraer la tabla de tokens a un tipo puro (`CompletionTokenTable`) con `replace(_:)` y
`lookup(_:)`, testeable en `VigoCore`, y dejar en el servicio solo el pegamento de MapKit. El
test sería «reemplazar la tabla no invalida los tokens ya entregados»; la mutación, reemplazarla
incondicionalmente.

---

### H-14 · El comentario «later refinements are dropped» ya no describe el código
**`MapKitAddressSearchService.swift:56-61`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** deuda

El comentario declara una invariante —«los refinamientos posteriores se descartan; ese es el
coste deliberado»— que el código **no cumple**: se descarta la *lista de sugerencias*, pero se
adopta la *tabla de tokens*, que es la mitad que importa. Es exactamente el caso que el encargo
describe: un comentario que declara una invariante da el criterio, y aquí el criterio está
incumplido. Se arregla con H-13; hasta entonces, el comentario debería decir qué pasa de verdad.

---

### H-15 · `onCancel` difiere la limpieza y puede resumir la continuación siguiente
**`MapKitAddressSearchService.swift:78-82`** · **Severidad:** media · **Confianza:** media ·
**Categoría:** concurrencia

**Qué pasa.** El bloque `onCancel` no puede tocar estado del main actor, así que salta con
`Task { @MainActor in self.cancelPending() }`. Entre la cancelación y la ejecución de ese salto,
una consulta **nueva** puede haber instalado su propia continuación; entonces el salto la resume
con `[]` y llama a `completer.cancel()` sobre la consulta nueva.

**Cómo reproducirlo.** Difícil en producción, porque el debounce de 300 ms casi siempre deja
llegar el salto antes. Con `debounce: .zero` —el valor que usan los tests— la ventana es real.
Resultado: la sección «Direcciones» se queda vacía sin error y sin spinner, hasta la siguiente
pulsación.

**Por qué pasa.** Es el mismo patrón que el comentario de las líneas 111-118 rechaza
explícitamente para el delegado («a deferred task could resume a continuation that already
belongs to the next query») — y aquí sí se usa.

**Cómo lo arreglaría.** Un contador de generación, que es el remedio que el propio comentario
del delegado propone como plan B:

```swift
private var generation = 0
// al instalar: generation += 1; let mine = generation
// en onCancel:  Task { @MainActor in self.cancelPending(ifGeneration: mine) }
```

**Cómo lo verificaría.** Con el tipo puro de H-44/H-13 extraído, un test de «cancelar la
generación N no toca la generación N+1». Mutación: ignorar la generación.

---

### H-16 · Sin timeout: `isSearching` puede quedarse pegado para siempre
**`AddressSearchModel.swift:48-58`** · **Severidad:** media · **Confianza:** media ·
**Categoría:** concurrencia

**Qué pasa.** `isSearching = true` se pone antes del `await` y solo se pone a `false` cuando la
llamada al servicio **retorna**. Si el completer nunca emite ni falla —red muerta a mitad de
sesión, MapKit throttleado, el caso de H-17— la continuación no se resume, la tarea no termina,
y la hoja muestra «Buscando direcciones…» indefinidamente. Peor: mientras `isSearching == true`,
la condición de la línea 309 de `MapSearchSheet` **suprime** el `ContentUnavailableView`, así que
tampoco se dice «no hay resultados».

**Cómo lo arreglaría.** Un `withTimeout` alrededor de la llamada al servicio, con un límite
generoso (3–5 s), que ponga `failed = true` y `failure = .unavailable`. Es un tipo puro y
testeable, y no hay ninguno hoy en el proyecto.

**Cómo lo verificaría.** `AddressSearchModelTests.searchTimesOut`, con un
`StubAddressSearchService` cuyo `suggestions` nunca retorne (`await Task.never()` o un
`CheckedContinuation` que nadie resuma) y un timeout inyectado corto:
`#expect(model.isSearching == false)` y `#expect(model.failed)`. Mutación: quitar el timeout.

---

### H-17 · Un `queryFragment` repetido puede dejar la continuación colgada
**`MapKitAddressSearchService.swift:76`** · **Severidad:** media · **Confianza:** baja ·
**Categoría:** concurrencia · **(no verificado — razonamiento)**

**Qué pasa.** Si `trimmed` coincide con el `queryFragment` que el completer ya tiene, es
razonable que MapKit no considere que hay una consulta nueva y no vuelva a llamar al delegado.
La continuación se queda instalada hasta que otra consulta la retire.

**Cómo reproducirlo (hipótesis).** Escribir «abc», dejar que se resuelva, teclear «d» y borrarla
antes de 300 ms: el debounce colapsa las dos pulsaciones en una sola llamada con «abc», que es
el fragmento vigente.

**Cómo lo arreglaría.** Corto-circuitar en el servicio: si `trimmed == completer.queryFragment`
y ya hay resultados, resumir inmediatamente con lo que hay en `completions`, sin tocar el
completer. Con H-16 implementado, el peor caso deja de ser un cuelgue permanente.

**Cómo lo verificaría.** Solo en dispositivo, o con el tipo puro de H-44 si el corto-circuito se
modela ahí. Marcarlo como comprobación manual en la lista de la tanda.

---

### H-18 · Toque y deslizar «Guardar» compiten por una sola resolución
**`MapSearchSheet.swift:341-379`** · **Severidad:** media · **Confianza:** media ·
**Categoría:** concurrencia

**Qué pasa.** La fila de dirección tiene dos caminos a `addresses.resolve(_:)`: el toque
(línea 344) y el deslizamiento «Guardar» (línea 371). El toque está protegido con
`.disabled(addresses.resolving != nil)`; el deslizamiento **no lo está**. Y `resolving` es un
único `AddressSuggestion.ID` con `defer { resolving = nil }`, así que la primera resolución que
termine desbloquea las filas mientras la otra sigue viva.

Por debajo, `MapKitAddressSearchService.resolve` hace `activeSearch?.cancel()`: la segunda
resolución **mata** la primera, cuyo `search.start()` lanza y se traduce a `.unavailable`. El
usuario ve «No he podido buscar direcciones ahora mismo» aunque la segunda haya ido bien, y el
`pick` de la primera nunca ocurre.

**Cómo reproducirlo.** Tocar una fila de dirección y, mientras gira el spinner, deslizar otra
fila y pulsar «Guardar». Esperado: la ficha del lugar tocado. Real: un error, y —según qué gane—
puede abrirse el editor de lugar guardado en su lugar.

**Cómo lo arreglaría.** Lo mínimo: aplicar el mismo `.disabled(addresses.resolving != nil)` al
botón de deslizamiento. Lo correcto: convertir `resolving` en un conjunto, o serializar en el
modelo con una única tarea de resolución cuyo resultado se enrute por el ID pedido.

**Cómo lo verificaría.** `AddressSearchModelTests.concurrentResolutionsDoNotClobberEachOther`:
lanzar dos `resolve` con un stub que retrase la primera y comprobar que la primera no queda
marcada como fallida cuando la segunda termina. Mutación: volver a `resolving` como escalar con
`defer` incondicional. **También:** el eje «ser buen ciudadano» cuenta aquí — cada resolución es
una `MKLocalSearch` completa, y este camino puede gastar dos por una intención del usuario.

---

### H-19 · `AddressSuggestion.id` se regenera en cada emisión
**`MapKitAddressSearchService.swift:102`** · **Severidad:** baja · **Confianza:** media ·
**Categoría:** rendimiento

`UUID()` nuevo por resultado y por emisión significa que `ForEach(addresses.suggestions)`
reconstruye todas las filas cada vez, aunque el texto no haya cambiado, y que `resolving ==
suggestion.id` deja de casar si la lista se refresca a mitad de una resolución. Una identidad
derivada de `title + subtitle` sería estable y seguiría sirviendo de token. (Se solapa con H-13:
arreglar aquel reduce mucho la frecuencia.)

---

### H-20 · `failed` sobrevive a la consulta siguiente
**`AddressSearchModel.swift:68-84`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** UX

Un `resolve` fallido deja `failed = true` y `failure` puestos. `update(query:)` los limpia, pero
solo si la consulta tiene ≥3 caracteres o si baja del mínimo. Si el usuario falla una resolución
y **no** vuelve a escribir —simplemente toca otra sugerencia que sí funciona— el mensaje de
error de la línea 294 sigue debajo de la lista mientras la ficha se abre. `resolve` debería
limpiar `failed` también en el camino de éxito, o la vista debería atar el mensaje al intento
concreto.

---

### H-21 · La sección «Direcciones» se dibuja siempre, aunque esté vacía
**`MapSearchSheet.swift:283-306`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** UX

La `Section` con cabecera «Direcciones» y el pie de dos líneas sobre privacidad se renderizan
incondicionalmente en cuanto hay texto. Con una consulta de dos letras —donde el buscador de
direcciones ni siquiera arranca— el resultado es una cabecera, nada debajo, un pie largo, y
justo después el `ContentUnavailableView` diciendo que no hay resultados. Envolver la sección en
`if addresses?.isSearching == true || !(addresses?.suggestions.isEmpty ?? true) || addresses?.failed == true`.

---

### H-22 · Con 1–2 caracteres afirma «No hay resultados» sin haber buscado direcciones
**`MapSearchSheet.swift:308-311`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** UX

**Qué pasa.** La condición del estado vacío no distingue «he buscado y no hay nada» de «no he
buscado porque la consulta es demasiado corta».

**Cómo reproducirlo.** Teclear `zz`. Paradas: 0. Líneas: 0 (ninguna contiene «zz»).
`AddressSearchModel` corta por el mínimo de 3 caracteres, así que `isSearching == false` y
`suggestions` está vacío. Resultado: `ContentUnavailableView.search(text: "zz")` — «No hay
resultados para "zz"» — cuando en realidad nadie ha preguntado por direcciones.

**Cómo lo arreglaría.** Exponer el umbral y consultarlo en la condición, o —mejor— hacerlo parte
del tipo puro de H-44, que sabría devolver un estado `.queryTooShort` distinto de `.noResults`.

**Cómo lo verificaría.** Test del tipo puro: `SearchSections.for(query: "zz", …).emptyState == .tooShort`.
Mutación: colapsar los dos estados en uno.

---

### H-23 · El texto de ayuda del estado vacío ignora dos de las cinco secciones
**`MapSearchSheet.swift:247-253`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** UX

La condición mira trayectos, lugares y favoritas, pero no `nearby` ni `lines`. Como
`routesWithService()` prácticamente siempre devuelve 45 rutas, el usuario nuevo ve a la vez
«Busca una parada por nombre o número, o una dirección de Vigo» **y** una lista enorme de
líneas. El texto está pensado para una pantalla vacía y se muestra en una llena. Además va suelto
en la raíz del `List`, sin `Section`, con el aspecto de una fila más.

---

### H-24 · 45 líneas no interactivas dominan el estado vacío
**`MapSearchSheet.swift:241-245`, `422-428`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** UX

**Qué pasa.** «Líneas con servicio» lista las **45** rutas del feed, y cada fila es
deliberadamente no interactiva (comentario de la línea 420: «no hay consulta stopID-por-routeID
en el repositorio»). Es, con diferencia, la sección más larga de una hoja cuyo propósito es
buscar, y no se puede hacer nada con ella.

**Cómo lo arreglaría.** Dos opciones, en este orden de preferencia:
1. **Hacerlas útiles.** Añadir `stopIDs(routeID:)` a `TransitRepository` —la tabla `stopRoute`
   ya tiene el índice `stopRoute_routeID`, así que es una consulta de una línea— y que tocar una
   línea filtre la capa de paradas del mapa. Esto convierte la razón declarada del comentario en
   trabajo hecho.
2. Si no, colapsarla: mostrar 6–8 y un «Ver todas». La sección deja de competir con «Cerca de
   ti», que es la que responde a la pregunta que trae al usuario.

---

### H-25 · `matchingLines` usa `contains`: «a» devuelve 44 de 45 líneas
**`MapSearchSheet.swift:260-267`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** UX

**Qué pasa.** El filtro de líneas es una subcadena sobre `shortName` **o** `longName`, sin
prefijo, sin límite y sin puntuación de relevancia. La búsqueda de paradas, en cambio, prioriza
prefijos. Los dos conviven en la misma hoja con reglas distintas.

**Cómo reproducirlo.** Medido contra las 45 rutas reales:

```
"a"        -> 44 líneas    "c"        -> 27 líneas
"1"        -> 20 líneas    "h"        -> 13 líneas
"15"       ->  3 líneas    "hospital" ->  4 líneas
```

Con `a` la sección «Líneas» tiene 44 filas y entierra las paradas que hay debajo.

**Cómo lo arreglaría.** Misma escalera que las paradas: `shortName` exacta primero, luego prefijo
de `shortName`, luego contenido de `longName`; tope de 5–8 filas. Y hacerlo en `VigoCore`
(véase H-45), no en la vista.

**Cómo lo verificaría.** `LineMatchingTests.shortQueryDoesNotMatchEveryLine` sobre el tipo puro:
`#expect(LineMatch.matches(query: "a", in: routes).count <= 8)` y
`#expect(LineMatch.matches(query: "15", in: routes).map(\.shortName) == ["15A","15B","15C"])`.
Mutación: volver a `contains` sin tope.

---

### H-26 · `matchingLines` se recalcula dos veces por evaluación de `body`
**`MapSearchSheet.swift:277-280`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** rendimiento

Es una propiedad calculada usada dos veces (`!matchingLines.isEmpty` y `ForEach(matchingLines)`),
así que cada evaluación de `body` pliega **180 cadenas** (45 rutas × 2 nombres × 2 usos). Medido:
0,278 ms por pasada en un Mac, así que ~0,56 ms por `body` — comparable al coste de la propia
consulta a SQLite, y `body` se reevalúa mucho más de una vez por pulsación (`@Observable` de
favoritas, lugares guardados, `location.coordinate` en cada fix de GPS). Se arregla solo si el
filtro se calcula una vez por consulta y se guarda en `@State`, que es lo que propone H-45.

---

### H-27 · `stopRow` con `.buttonStyle(.plain)` y sin `contentShape`
**`MapSearchSheet.swift:314-339`** · **Severidad:** media · **Confianza:** baja ·
**Categoría:** accesibilidad · **(no verificado — razonamiento: necesita simulador)**

**Qué pasa.** El `Button` de `stopRow` lleva `.buttonStyle(.plain)` y su etiqueta es un
`VStack(alignment: .leading)` **sin `Spacer`**. Con estilo `.plain` no se aplica la forma de fila
completa que da el estilo por defecto de `List`, así que el área sensible es el marco del
contenido: la mitad derecha de la fila —la más ancha, con nombres cortos como «Beiramar -
Pescadores»— no responde al toque.

`addressRow` y `nearbyRow` **sí** llevan `Spacer`, así que se libran. Es solo `stopRow`, que es la
fila más frecuente de la hoja.

**Cómo lo arreglaría.** `.contentShape(Rectangle())` sobre la etiqueta, o añadir
`Spacer(minLength: 0)` como en las otras dos filas.

**Cómo lo verificaría.** En dispositivo: tocar el borde derecho de una fila de parada con nombre
corto. Es exactamente el tipo de comprobación que el propietario ya hace en la lista de
verificación de cada fase.

---

### H-28 · Base sin importar y feed caducado son invisibles en el buscador
**`MapSearchSheet.swift`, toda la hoja** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** UX

**Qué pasa.** `MapSearchSheet` **nunca** consulta `environment.hasData` ni
`environment.timetableOutOfDate`. Comprobado con grep: los únicos consumidores son
`RootView.swift:37`, `FavouritesView.swift:143` y `StopDetailView.swift:83,204`.

**Consecuencia.** Con la base vacía —primer arranque con la descarga fallida, o import
interrumpido— `searchStops` devuelve `[]`, `nearbyStops` devuelve `[]` y `routesWithService`
devuelve `[]`. El buscador dice «Busca una parada por nombre o número» y luego «No hay resultados
para X», que es exactamente el mismo mensaje que daría si la parada no existiese. El usuario no
tiene forma de saber que el problema es que no hay datos.

**Cómo lo arreglaría.** Una comprobación al principio de `shortcuts` y de `searchResults`:

```swift
if !environment.hasData {
    ContentUnavailableView("Sin datos del feed", systemImage: "tray",
        description: Text("Todavía no se ha importado ningún horario. Actualiza desde Ajustes."))
}
```

Y, con datos pero caducados, la misma tira que ya usan `FavouritesView` y `StopDetailView` —las
paradas siguen siendo válidas, así que es un aviso, no un bloqueo.

**Cómo lo verificaría.** Estado del tipo puro de H-44: `SearchSections.for(query:…, hasData: false)`
debe devolver `.noFeed`. Mutación: ignorar `hasData`.

---

### H-29 · Permiso de ubicación denegado: «Cerca de ti» desaparece sin explicación
**`MapSearchSheet.swift:93-101, 235-239`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** UX

`LocationProvider.start()` sale por `guard isAuthorized`, así que `location.coordinate` se queda
en `nil`, el `.task(id: roundedCoordinate)` sale por su propio `guard`, y `nearby` nunca se
puebla. La sección simplemente no aparece. `LocationProvider` ya expone `isDenied` y `failure`, y
ninguno de los dos se usa aquí. La fila «Mi ubicación» sí se degrada correctamente
(`.disabled(location.coordinate == nil)`), lo cual demuestra que el patrón estaba pensado y no se
aplicó a la sección.

---

### H-30 · Dos `CLLocationManager` vivos a la vez mientras la hoja está sobre el mapa
**`MapSearchSheet.swift:50`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** rendimiento

Comprobado con grep: hay exactamente dos `LocationProvider()`, uno en `MapScreen.swift:21` y otro
aquí. Cuando la hoja se presenta desde el mapa —el caso normal— los dos están arrancados,
cada uno con su `CLLocationManager` en `startUpdatingLocation()` a 100 m. El comentario de la
línea 47-49 **lo reconoce** («same as `PlacePickerView` used to run alongside `MapScreen`»), lo
cual es honesto pero también dice que la deuda de la Fase 7 se heredó en vez de pagarse.

El coste no es solo batería: los dos entregan fixes independientes, así que `roundedCoordinate`
de la hoja y la posición del mapa pueden discrepar durante un instante, y la distancia que
`nearbyRow` muestra no es necesariamente la que muestra `MapPlaceSheet`.

**Cómo lo arreglaría.** Pasar la coordenada hacia abajo. `MapScreenModel` ya recibe
`updateCurrentLocation(_:)`; `MapSearchSheet` podría aceptar un `currentLocation: Coordinate?`
opcional y levantar su propio proveedor **solo** cuando no le den ninguno — que es el caso de los
dos editores en la pestaña Favoritas.

---

### H-31 · Una pulsación anterior a `.task` se pierde para las direcciones
**`MapSearchSheet.swift:74, 82-86`** · **Severidad:** baja · **Confianza:** media ·
**Categoría:** bug

`addresses` se crea dentro de `.task`, que corre después del primer render.
`.onChange(of: query)` hace `addresses?.update(query:)`: si `addresses` es todavía `nil`, esa
pulsación **no se reintenta nunca**, porque no hay ningún `update` posterior con el texto
acumulado hasta que el usuario vuelva a teclear. En la práctica es improbable (el teclado tarda
más en aparecer que el `.task` en correr), pero el fallo es silencioso y no cuesta nada cerrarlo:
crear el modelo en `init` o en la declaración del `@State`, o llamar
`addresses?.update(query: query)` al final del `.task`.

---

### H-32 · El picker anidado cambia la hoja externa mientras la interna se cierra
**`MapSearchSheet.swift:106-111`** · **Severidad:** baja · **Confianza:** baja ·
**Categoría:** UX · **(no verificado — razonamiento)**

`MapPointPickerView` llama `onPick(centre); dismiss()`. `onPick` acaba en
`model.select(place)`, que cambia `state.mode` de `.searching` a `.place`, lo que **sustituye el
contenido de la hoja externa** en el mismo ciclo en que la interna se está descartando. Es
exactamente la clase de carrera que el comentario de `onCancel` (líneas 36-42) documenta haber
sufrido ya. Invertir el orden (`dismiss()` y luego `onPick` en el siguiente ciclo) o dejar que el
padre observe el resultado sería más seguro. Comprobación en dispositivo.

---

### H-33 · «Elegir en el mapa» nunca geocodifica el punto elegido
**`MapSearchSheet.swift:106-111`** vs **`MapScreenModel.swift:153-162`** · **Severidad:** alta ·
**Confianza:** alta · **Categoría:** invariante

**Qué pasa.** Hay **dos** caminos para soltar un pin, y solo uno resuelve la calle.

- Pulsación larga en el mapa → `MapScreenModel.dropPin(at:)` → selecciona con la etiqueta de
  respaldo, llama a `MapKitPlaceResolver.resolve`, y **vuelve a seleccionar** con
  `name: resolved.name, subtitle: resolved.subtitle`. El usuario ve «Rúa do Areal, 12».
- «Elegir en el mapa» en el buscador → `pick(.droppedPin(Coordinate(...)))` →
  `MapScreenModel.select(_:)`, que **no** geocodifica nada. El usuario ve «Punto en el mapa»,
  siempre.

**Por qué importa.** El comentario de la línea 155-156 dice que esta fila existe porque «es la
ruta accesible a soltar un pin en cualquier sitio, la única cosa que la pulsación larga del mapa
no puede alcanzar con VoiceOver». Es decir: **la ruta accesible da un resultado estrictamente
peor que la inaccesible**. El hueco que la Fase 7 declara cerrado está cerrado en alcance y
abierto en calidad. Y no hay ninguna razón de privacidad que lo justifique: es un punto que el
usuario ha elegido a propósito, que es exactamente el criterio que `MapKitPlaceResolver`
documenta como suficiente.

**Cómo reproducirlo.** Abrir el buscador, «Elegir en el mapa», centrar sobre una calle conocida,
«Elegir». Esperado: la ficha con el nombre de la calle. Real: «Punto en el mapa».

**Cómo lo arreglaría.** Que el picker del buscador termine en el mismo sitio que la pulsación
larga. En `MapScreen.sheetContent`, para `.explore`:

```swift
onPick: { place in
    if place.origin == .droppedPin {
        Task { await model.dropPin(at: place.coordinate) }
    } else {
        model.select(place)
    }
}
```

Para `.endpoint` y `.standalone` no hay `MapScreenModel`, así que el resolver tendría que
inyectarse en la propia hoja — que es un argumento más para que `MapSearchSheet` reciba un
`MapPlaceResolving` como dependencia en lugar de que cada llamante improvise.

**Cómo lo verificaría.** `MapScreenModelTests` (no existe hoy; el modelo ya acepta un
`resolver:` inyectable en `init`, así que es testeable **en el target de app** con un stub que
imite `StubAddressSearchService`): «un pin que llega desde el buscador se renombra igual que uno
de pulsación larga». Mutación: volver a `model.select(place)` directo.

---

### H-34 · Los trayectos guardados no pasan por `pick(_:)` — el embudo ya no es único
**`MapSearchSheet.swift:198-212`** · **Severidad:** alta · **Confianza:** alta ·
**Categoría:** invariante

**Qué pasa.** El invariante 5 del proyecto dice que los seis sitios que producen un resultado
pasan por `pick(_:)`, y la §12.1 del plan de la Fase 12 construye toda la fase sobre esa
premisa. No es cierto:

- `case .explore:` llama `onPickJourney(journey)` — nunca toca `pick`.
- `case .endpoint(let role):` llama **`onPick(...)` directamente** con uno de los dos
  `journey.mapEnds`, saltándose `pick(_:)` a un paso de distancia.

El segundo es el que hace daño: es un lugar elegido en el buscador, indistinguible de tocar una
parada, que jamás pasará por el registro de recientes.

**Cómo lo arreglaría.** Es de una línea: `case .endpoint(let role): pick(role == .origin ? ends.origin : ends.destination)`.
`.explore` sí es legítimamente distinto —planifica un trayecto entero, no elige un lugar— pero
merece una nota que lo diga en el código, porque hoy parece un olvido.

**Cómo lo verificaría.** Cuando exista la Fase 12: un test del store de recientes que compruebe
que elegir el extremo de un trayecto guardado desde `.endpoint` registra un reciente. Antes de
eso, es una revisión de código, no un test.

---

### H-35 · El sheet reimplementa `MapPlace.savedPlace(_:)`, que ya existe en VigoCore
**`MapSearchSheet.swift:220-221`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** deuda

```swift
// en la vista
pick(MapPlace(place: place.place, subtitle: place.anchor.resolvedStop?.name,
              origin: .savedPlace(place.id)))
// en MapPlace.swift:80
public static func savedPlace(_ saved: SavedPlace) -> MapPlace {
    MapPlace(place: saved.place, subtitle: saved.anchor.resolvedStop?.name,
             origin: .savedPlace(saved.id))
}
```

Idénticas. La fábrica existe, es pública, y este es su único uso posible. `pick(.savedPlace(place))`.

---

### H-36 · `EndpointPickerSheet` es un segundo selector delante del buscador único
**`SavedJourneyEditorView.swift:146-197`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** deuda

**Qué pasa.** La Fase 7 eliminó `PlacePickerView`, pero dejó en pie `EndpointPickerSheet`: una
hoja que muestra «Lugares guardados» —**la misma sección que `MapSearchSheet` ya muestra en su
estado vacío**— más un botón «Elegir otro lugar» que abre `MapSearchSheet` en una tercera hoja
anidada. Para buscar una dirección desde el editor de trayectos hacen falta **tres** hojas
apiladas y dos toques extra.

**Por qué existe.** Aparentemente para producir el enlace vivo `.savedPlace(place)`. Pero eso ya
lo hace `MapSearchSheet`: su fila de lugar guardado produce un `MapPlace` con origen
`.savedPlace(id)`, y `MapPlace.savedEndpointInput` (líneas 158-165 de `MapPlace.swift`) conserva
el `placeID`. La razón por la que se creó ya no aplica.

**Cómo lo arreglaría.** Borrar `EndpointPickerSheet` y presentar `MapSearchSheet(purpose:
.standalone(title:))` directamente desde `endpointRow`, como ya hace `SavedPlaceEditorView`. Es
la misma reducción que la Fase 7 hizo con `PlacePickerView`, sobre el mismo argumento.

**Cómo lo verificaría.** Comprobación en dispositivo: elegir un lugar guardado como destino de un
trayecto guardado y confirmar que renombrar el lugar después renombra el extremo — es decir, que
el enlace vivo sobrevive al cambio.

---

### H-37 · `SavedPlaceEditorView.input(for:)` duplica `MapPlace.savedEndpointInput`
**`SavedPlaceEditorView.swift:191-196`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** deuda

Dos derivaciones distintas de «ancla a partir de un `MapPlace`» conviviendo: el editor de lugares
hace un `switch` sobre `place.place`; el de trayectos usa `place.savedEndpointInput`. Hoy
coinciden, porque la regla del stop es la misma, pero son dos sitios que hay que cambiar a la vez
si la regla cambia — y la regla es una de las invariantes duras del proyecto («nada guarda un
`Stop` serializado»). El editor de lugares debería usar `place.savedEndpointInput.anchor`.

---

### H-38 · `MapPlace.savedEndpoint` etiqueta como `.address` un extremo anclado a parada
**`VigoCore/Sources/VigoCore/MapFlow/MapPlace.swift:135`** · **Severidad:** media ·
**Confianza:** alta · **Categoría:** corrección

```swift
origin: endpoint.placeID.map { .savedPlace($0) } ?? .address
```

Un `SavedEndpoint` sin `placeID` puede perfectamente estar anclado a una parada
(`anchor == .stop(stop)`) o venir de un pin (`.coordinate`). Etiquetarlos todos como `.address`
tiene tres consecuencias observables:

1. `symbolName` devuelve `"mappin.and.ellipse"` para lo que es una parada.
2. `MapPlace.stop` devuelve `nil`, así que la ficha no ofrece llegadas ni la estrella de
   favorito para una parada real.
3. `savedEndpointInput` cae a `.coordinate(coordinate)` y **pierde el `stopID`** al volver a
   guardar.

Hoy solo se alcanza a través de `.endpoint` con un trayecto guardado, que además se salta `pick`
(H-34) — pero en cuanto H-34 se arregle, este camino empezará a generar recientes con
`originKind: "address"` sobre paradas. Lo correcto es derivar el origen del ancla:
`.stop(stop)` cuando `anchor.resolvedStop != nil`, `.droppedPin` en otro caso.

**Cómo lo verificaría.** Test en `VigoCore`: `MapPlaceTests.savedEndpointKeepsItsStop`,
`#expect(MapPlace.savedEndpoint(endpointAnchoredToStop).stop != nil)`. Mutación: el `?? .address`
actual.

---

### H-39 · `matchingLines` no usa `normalizedLineName`
**`MapSearchSheet.swift:264-265`** · **Severidad:** nit · **Confianza:** alta ·
**Categoría:** deuda

`TextNormalization` tiene dos funciones y el buscador de líneas usa la de paradas.
`normalizedLineName` es la que quita el punto final que el feed pone en las variantes (`9B.`,
`4A.`) y la que `DATA-SOURCES.md` §3.6 documenta como la forma canónica de un nombre de línea.
Hoy no muerde porque todas las rutas con punto son fantasma y `routesWithService()` ya las filtra;
si eso cambia, buscar «9B» no encontrará «9B.». Un `normalizedLineName` en la comparación de
`shortName` lo cierra.

---

### H-40 · El orden prefijo-antes-que-contenido no está cubierto
**`RepositoryTests.swift:136`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Verificado por mutación.** Cambiando
`return Array((prefixed + contained).prefix(limit))` por
`return Array((contained + prefixed).prefix(limit))`, **los 20 tests de `RepositoryTests` pasan**
y la suite entera de 321 sigue verde. El comentario de la línea 208-209 declara la regla («so
"coru" puts "Rúa da Coruña" above a stop that merely mentions it») y nada la comprueba.

**Por qué no lo pilla el fixture.** Las cuatro paradas del fixture no tienen ningún caso donde el
mismo término sea prefijo de un nombre y aparezca a media palabra en otro. `"urzaiz"` casa con una
sola fila.

**Cómo lo arreglaría.** Añadir al fixture una parada llamada `Coruña, Rúa da` junto a la existente
`Rúa da Coruña 26`, o —mejor, porque no toca el fixture compartido— un caso en
`RealFeedIntegrationTests`: `searchStops("beiramar").first?.name` debe empezar por «Beiramar»
(«Beiramar - Pescadores», que es prefijo) y no por «Avda. Beiramar…», que solo lo contiene.
Comprobado contra el feed real: hoy devuelve exactamente eso, así que el test sería verde de
entrada y la mutación lo tumbaría.

---

### H-41 · La rama de prefijo numérico no está cubierta
**`RepositoryTests.swift:146`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Verificado por mutación.** Rompiendo el patrón de la línea 203
(`"\(digits)%"` → `"ZZZ\(digits)%"`), la suite completa sigue verde. `searchByNumber` solo
ejercita la coincidencia **exacta**; toda la rama de prefijo de código —y con ella H-02 y H-03—
es territorio no cubierto.

**Cómo lo arreglaría.** El fixture ya tiene códigos `6930`, `14264` y `20113`.
`#expect(try repository.searchStops("2011").contains { $0.id == StopID("4856") })` cubre el
prefijo, y `#expect(try repository.searchStops("02011")…)` cubriría H-03.

---

### H-42 · `limit` no está cubierto en ninguna rama
**`RepositoryTests.swift:136`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Verificado por mutación.** Quitando `.limit(limit)` de las dos consultas por nombre, la suite
sigue verde. Ningún test pasa un `limit` explícito ni comprueba el tamaño del resultado contra él.
Es lo que deja pasar H-02.

---

### H-43 · El filtro exacto de radio de `nearbyStops` no está cubierto
**`RepositoryTests.swift:163`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Verificado por mutación.** Sustituyendo `return d <= radiusMetres ? (stop, d) : nil` por
`return (stop, d)` —es decir, **eliminando el filtro de radio por completo**— la suite sigue
verde. El test `nearbyRadius` pasa porque a 50 m la **caja delimitadora** ya excluye Urzáiz por
sí sola; el `haversine` posterior nunca se pone a prueba.

**Por qué importa.** La caja es cuadrada y el radio es circular: dentro de la caja hay puntos a
hasta √2 × radio del centro. Con el filtro roto, «Cerca de ti» a 800 m incluiría paradas a
1130 m, y el número que la fila muestra («en línea recta») sería el correcto para una parada que
no debería estar en la lista.

**Cómo lo arreglaría.** Un test con una parada colocada a propósito en la esquina de la caja:
`nearbyStops(lat, lon, radiusMetres: 500)` no debe contener una parada a 600 m que sí cae dentro
de la caja de ±500 m en latitud **y** longitud. Con el feed real es fácil de construir; con el
fixture hace falta una parada más.

*(Nota: la mutación complementaria —radio terrestre en km en `haversineMetres`— **sí** se detecta,
por 51 fallos en `WalkModelTests` y compañía. La geometría está cubierta; lo que no lo está es su
**uso** aquí.)*

---

### H-44 · «Consulta → secciones y su orden» es hoy inverificable
**`MapSearchSheet.swift:193-312`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** testabilidad

**Qué pasa.** La decisión más importante del buscador —qué secciones se dibujan, en qué orden, y
qué se dice cuando no hay nada— vive entera en dos `@ViewBuilder` de una `View`, y por tanto solo
se puede comprobar en simulador. Ocho decisiones distintas, ninguna testeable: qué secciones
según el `Purpose` (`showsSavedJourneys`, `showsCurrentLocation`), la condición del texto de
ayuda (H-23), la condición del estado vacío (H-22), y si la sección «Direcciones» se dibuja
(H-21).

**Cómo lo arreglaría.** Extraer un tipo puro a `VigoCore/Sources/VigoCore/MapFlow/SearchSections.swift`.
Firma concreta:

```swift
public enum SearchSection: Sendable, Hashable {
    case currentLocation, pickOnMap
    case savedJourneys, savedPlaces, favourites, nearby, lines
    case stops, matchingLines, addresses
}

public enum SearchEmptyState: Sendable, Hashable {
    case none                 // hay algo que enseñar
    case noFeed               // hasData == false
    case queryTooShort(Int)   // menos del mínimo del geocoder
    case noResults(String)
    case gettingStarted       // vacío, sin nada guardado
}

public struct SearchLayout: Sendable, Hashable {
    public let sections: [SearchSection]   // en orden de dibujo
    public let emptyState: SearchEmptyState
}

public enum SearchLayoutBuilder {
    public static func layout(
        purpose: SearchPurpose,          // enum espejo de MapSearchSheet.Purpose, sin la vista
        query: String,
        hasData: Bool,
        counts: SearchCounts,            // stops, lines, addresses, nearby, saved…, favourites
        addressState: AddressSectionState // idle | tooShort | searching | results | failed
    ) -> SearchLayout
}
```

La vista se queda con `ForEach(layout.sections)` y un `switch`. **La decisión sale del simulador
y entra en `swift test`.** Este es el corte que más cobertura compra por línea escrita, y además
es donde caben H-21, H-22, H-23 y H-28 como casos de test en vez de como inspecciones visuales.

**Cómo lo verificaría.** `SearchLayoutTests.swift`, un caso por hallazgo:
`layout(query: "zz", …).emptyState == .queryTooShort(3)`;
`layout(hasData: false, …).emptyState == .noFeed`;
`layout(purpose: .standalone, …).sections` no contiene `.savedJourneys`.
Mutaciones: colapsar `.queryTooShort` en `.noResults`, ignorar `hasData`, mostrar
`.savedJourneys` en `.standalone`.

---

### H-45 · `matchingLines` es lógica de decisión atrapada en la vista
**`MapSearchSheet.swift:260-267`** · **Severidad:** media · **Confianza:** alta ·
**Categoría:** invariante

El invariante 6 dice que la lógica verificable vive en `VigoCore`. `matchingLines` es una regla
de emparejamiento y de relevancia —hermana de `searchStops`, que sí está en el paquete— escrita
dentro de una `View`. Debería mudarse a
`VigoCore/Sources/VigoCore/MapFlow/LineMatching.swift`:

```swift
public enum LineMatching {
    /// Rutas que casan con la consulta, mejor primero, con tope.
    public static func matches(query: String, in routes: [Route], limit: Int = 8) -> [Route]
}
```

Con eso, H-25 (el `contains` sin tope), H-26 (el recálculo doble) y H-39 (`normalizedLineName`)
se arreglan y se cubren de una vez.

---

### H-46 · §12.4 del plan enumera seis llamantes de `pick` que no coinciden con el código
**`PLAN-FASES-8-13.md:851`** · **Severidad:** media · **Confianza:** alta · **Categoría:** deuda

El plan dice: «Hay seis sitios que llaman a `pick` (parada, dirección, POI, pin, cercana,
favorita)». Contrastado con el código, los llamantes reales son:

| Llamante | Línea | Origen producido |
|---|---|---|
| `pickCurrentLocation()` | 167 | `.currentLocation` |
| `MapPointPickerView` | 108 | `.droppedPin` |
| fila de lugar guardado | 220 | `.savedPlace` |
| `stopRow` (resultados **y** favoritas) | 316 | `.stop` |
| `addressRow` | 346 | `.address` |
| `nearbyRow` | 389 | `.stop` |

Dos discrepancias que importan para la Fase 12:

- **`.pointOfInterest` no se produce nunca aquí.** Solo lo produce
  `MapScreenModel.selectPointOfInterest`, desde un toque en el mapa, que no pasa por el
  buscador. El plan lo lista entre lo que «se guarda» (§12.1) y entre los llamantes de `pick`
  (§12.4); las dos cosas son falsas hoy. O bien el registro no va solo en `pick`, o bien
  `originKind: "poi"` es una columna muerta.
- **«favorita» y «cercana» son ambas `stopRow`/`nearbyRow` con origen `.stop`**, y el llamante
  que el plan omite —el lugar guardado— sí existe y está en la lista de exclusiones. La cuenta
  sale a seis por casualidad.

**Cómo lo arreglaría.** Antes de escribir la Fase 12: corregir §12.1 y §12.4, decidir si el POI
del mapa debe registrarse (creo que sí — es tan «una búsqueda» como un pin, y es el caso que la
sección de recientes haría más útil), y en ese caso el punto de registro no es `pick` sino
`MapScreenModel.select(_:)` **más** `pick`, o mejor: un único `recents.record(_:)` llamado desde
`MapNavigationState.select`, que ya es el embudo real de todo lo que acaba en la ficha.

---

### H-47 · Todos los pines recientes se llamarían «Punto en el mapa»
**`PLAN-FASES-8-13.md:789`** · **Severidad:** media · **Confianza:** alta · **Categoría:** UX

Consecuencia directa de H-33. El plan dice, con razón, que un punto suelto del mapa **sí** debe
guardarse («volver a él es justo lo que cuesta trabajo sin recientes»). Pero como el pin del
buscador nunca se geocodifica, cada uno entra en la tabla con `name = "Punto en el mapa"`. El
`dedupKey` (`pt:lat:lon:punto en el mapa`) los distingue correctamente, así que **no** colapsan
en una fila — el resultado es peor: una lista de hasta diez filas idénticas e indistinguibles.

Arreglar H-33 antes de la Fase 12 convierte esto en un no-problema. Hacerlo después significa
que la primera versión de «Recientes» nace rota para uno de los cuatro orígenes que guarda.

---

### H-48 · El redondeo a ~11 m vive en un `private var` de la vista
**`MapSearchSheet.swift:175-180`** · **Severidad:** baja · **Confianza:** alta ·
**Categoría:** deuda

`roundedCoordinate` es la definición de «el mismo sitio» del proyecto, y §12.2 del plan la cita
explícitamente como la fuente del redondeo de `dedupKey`. Pero es `private` y está dentro de una
`View`, así que `RecentSearchKey.swift` tendrá que reescribirla: **una tercera copia** de una
regla que ya está duplicada en el enunciado del plan. Debería ser
`Coordinate.rounded(toDecimals:)` en `VigoCore`, testeable, y usada por los dos.

---

## 4. Mapa del motor

El recorrido real, con cada salto de actor, cada consulta y cada llamada de red.

```
                        [ MapScreen — MapBrowseBar ]
                                    │ model.beginSearch()
                                    ▼
                        state.mode = .searching
                                    │
                   .sheet(isPresented:) → sheetContent(model)
                                    ▼
              ┌───────────  MapSearchSheet (main actor)  ───────────┐
              │                                                     │
   .task #1 ──┤ addresses = AddressSearchModel(environment.addressSearch)
              │ location.requestPermissionIfNeeded(); location.start()
              │        └─ 2.º CLLocationManager  ← H-30
              │
   .task #2 ──┤ Task.detached(.userInitiated)
              │   repository.routesWithService()
              │     SQL: SELECT * FROM route WHERE EXISTS(SELECT 1 FROM trip …)
              │     EQP: SCAN route + CORRELATED SCALAR SUBQUERY (trip_on_routeID)
              │     medido: 0,475 ms  → lines: [Route] (45)
              │
   .task #3 ──┤ id: roundedCoordinate  (lat/lon redondeadas a 4 decimales, ~11 m)
              │   Task.detached(.userInitiated)
              │     repository.nearbyStops(radius: 800, limit: 8)
              │       SQL 1: SELECT * FROM stop WHERE latitude BETWEEN … AND longitude BETWEEN …
              │              EQP: SEARCH stop USING INDEX stop_lat_lon (latitude>? AND latitude<?)
              │              → 67 candidatos dentro de la caja (medido)
              │       Swift: haversineMetres por candidato, orden, .prefix(8)   ← H-43 sin cubrir
              │       SQL 2..9: routeShortNames por parada superviviente (N+1, acotado a 8)
              │              EQP: COVERING INDEX stopRoute + trip_on_routeID
              │       medido: 0,812 ms (limit 8) / 2,211 ms (limit 40)
              │
   PULSACIÓN ─┤ .searchable → query
              │
              ├─ .onChange(of: query)   ★ MAIN ACTOR, SÍNCRONO ★           ← H-08
              │    repository.searchStops(query)
              │      TextNormalization.searchFolded(query)     ← H-01 sin escapar, H-10 sin puntuación
              │      si numérico:  vitrasaCode = ?             EQP: SEARCH stop_vitrasaCode
              │                    CAST(vitrasaCode AS TEXT) LIKE '…%'
              │                                               EQP: SCAN stop      ← H-03, H-04
              │                    return exact + prefix       ← H-02 supera limit
              │      si no:        searchName LIKE '…%'  ORDER BY searchName LIMIT 50
              │                                               EQP: SCAN stop USING INDEX stop_searchName  ← H-07
              │                    searchName LIKE '%…%' AND NOT LIKE '…%'
              │                    Array((prefixed + contained).prefix(50))       ← H-09, H-40
              │      medido: 0,27–0,58 ms
              │    → results: [Stop]
              │
              └─ addresses.update(query:)                                   ← H-31 si aún es nil
                   task?.cancel()                                           ← H-15 carrera de cancelación
                   guard trimmed.count >= 3   → si no, limpia y sale        ← H-22
                   isSearching = true
                   Task { @MainActor }
                     await Task.sleep(300 ms)                     ← DEBOUNCE
                     await service.suggestions(for:)              ← MapKitAddressSearchService
                       withTaskCancellationHandler {
                         withCheckedContinuation {
                           resumePending(with: [])   // retira la anterior
                           pending = continuation
                           completer.queryFragment = trimmed   ══► RED: MKLocalSearchCompleter
                         }                                        (región fija de Vigo,
                       } onCancel: { Task{@MainActor …} }          regionPriority = .required,
                                                                   SIN la ubicación del usuario ✓)
                     ◄══ completerDidUpdateResults  (MainActor.assumeIsolated)
                          completeResults():
                            completions = [UUID: MKLocalSearchCompletion]   ← H-13 sustitución tardía
                            resumePending(sugerencias)                      ← H-19 UUID nuevos
                          … emisiones posteriores vuelven a entrar aquí     ← H-13, H-14
                     (sin timeout)                                          ← H-16
                   suggestions = found ; isSearching = false

   ── body ──────────────────────────────────────────────────────────────
     query vacía → shortcuts: Trayectos │ Lugares │ Favoritas │ Cerca de ti │ Líneas(45)   ← H-24
     query llena → searchResults:
        Paradas (results)
        Líneas  (matchingLines: fold ×2 sobre 45 rutas, 2 veces por body)  ← H-25, H-26, H-45
        Direcciones (siempre dibujada)                                     ← H-21
        ContentUnavailableView.search                                      ← H-22, H-28

   ── elección ──────────────────────────────────────────────────────────
     stopRow / nearbyRow ─────► pick(.stop(stop))
     savedPlace row ──────────► pick(MapPlace(...))                        ← H-35
     "Mi ubicación" ──────────► pick(.currentLocation(coord))
     "Elegir en el mapa" ─────► MapPointPickerView → pick(.droppedPin(coord))
                                                     SIN geocodificación   ← H-33
     addressRow (toque) ──────► await addresses.resolve(suggestion)
                                  ══► RED: MKLocalSearch.start()   (1 por toque ✓)
                                  VigoSearchRegion.contains(...) → .outsideCoverage
                                  → pick(MapPlace(..., origin: .address))
     addressRow (deslizar) ───► await addresses.resolve(suggestion)
                                  ══► RED: otra MKLocalSearch     ← H-18 compite con la anterior
                                  → savingPlaceFrom (NO pasa por pick)
     trayecto guardado ───────► onPickJourney(...)  o  onPick(ends.origin)  ← H-34 SE SALTA pick

                                    │ pick → onPick
                                    ▼
     .explore     → MapScreenModel.select(place)  → state.mode = .place → ficha
     .endpoint    → MapRouteSheet.onPick(role, place) → model.setOrigin/setDestination → replanifica
     .standalone  → editor: place.place / place.savedEndpointInput        ← H-37, H-38
```

**Llamadas a Apple por flujo (contadas, invariante 2):**

| Flujo | `MKLocalSearchCompleter` | `MKLocalSearch` | `CLGeocoder` |
|---|---|---|---|
| Escribir «Praza de América» (16 pulsaciones) | 1 fragmento por pausa de 300 ms (2–4 en la práctica) | 0 ✓ | 0 |
| Tocar una sugerencia | — | 1 ✓ | 0 |
| Deslizar «Guardar» en una sugerencia | — | 1 | 0 |
| Tocar **y luego** deslizar la misma fila | — | **2**, la 1.ª cancelada ← H-18 | 0 |
| «Elegir en el mapa» → «Elegir» | — | 0 | **0** ← H-33 (debería ser 1) |
| Pulsación larga en el mapa | — | 0 | 1 ✓ |

**Ubicación del usuario:** ningún camino la envía. `completer.region` y `request.region` son
`VigoSearchRegion.region`, una constante; `MapKitPlaceResolver` solo recibe un punto que el
usuario ha pulsado. Verificado por lectura de los tres ficheros. *(No verificado — razonamiento:
si iOS adjunta la posición del dispositivo a las peticiones de MapKit por debajo de la API cuando
la app tiene permiso concedido, eso queda fuera del control del código; el proyecto ha hecho todo
lo que le corresponde.)*

---

## 5. Lo que está bien

No es cortesía; son decisiones que aguantan y que un refactor no debería deshacer sin entender
por qué están.

1. **La privacidad de la ubicación está de verdad implementada, no solo declarada.**
   `VigoSearchRegion` es una constante con `regionPriority = .required` en los dos sitios que
   hablan con MapKit, y la comprobación `contains` del lado de la app usa **exactamente** el mismo
   `span` que se le pasa a Apple, así que la caja pedida y la caja verificada coinciden (`±0,125°`
   de latitud, `±0,15°` de longitud). No hay desajuste de bordes. `MapKitPlaceResolver` gasta un
   párrafo justificando por qué geocodificar un punto pulsado no viola la promesa, y el argumento
   es correcto.

2. **Resolver solo al tocar.** La separación `MKLocalSearchCompleter` / `MKLocalSearch` es la
   forma correcta de esta API y está bien argumentada. El completer único para toda la vida de la
   app (`AppEnvironment.addressSearch`) es lo que hace que las sugerencias sean baratas.

3. **El seam `AddressSearching`.** Que el protocolo sea `@MainActor` en vez de `Sendable`, con la
   razón escrita, es la decisión correcta para una API basada en delegado de main thread — y es lo
   que permite que `AddressSearchModel` esté cubierto por tests sin tocar la red. El fichero de
   MapKit **declara por escrito que es el código de más riesgo y que no está cubierto**, y eso
   resultó ser exactamente donde vive H-13. Un proyecto que se marca a sí mismo sus zonas oscuras
   con precisión merece que se le note.

4. **`searchName` precalculado en el import.** Plegar en el importador y no en la consulta es lo
   correcto y es lo que hace que buscar cueste 0,3 ms. Y el plegado con `es_ES` maneja la «ñ» bien:
   comprobado sobre las 1154 filas reales, cero `ñ` en `searchName` y las consultas con y sin
   tilde/eñe devuelven idénticos resultados. Lo que le falta a `searchFolded` es la puntuación
   (H-10), no los acentos.

5. **`MapPlace` como `Place` + procedencia.** El comentario de las líneas 5-13 explica por qué
   `Place` no bastaba, y la conclusión es correcta: el planificador solo ve `place`, la UI ve
   `origin`. `savedEndpointInput` codifica las dos reglas del anclaje —nunca un `Stop`
   serializado, enlace vivo al lugar guardado— en un solo sitio.

6. **`Task.detached` para líneas y cercanía, y el redondeo a ~11 m del `.task(id:)`.** El motivo
   está escrito y es el correcto: el `id` se redondea, pero la tarea lee la coordenada viva, así
   que se limita *cuándo* se relanza sin volver stale el resultado. 11 m para alguien caminando
   (~1,4 m/s) es una consulta nueva cada ocho segundos como mucho — es el umbral adecuado, ni
   demasiado nervioso ni pegajoso.

7. **La cabecera «Elegir en el mapa» presente en los tres propósitos**, con el motivo de
   accesibilidad escrito al lado. La intención es exactamente la correcta; lo que falta es que el
   resultado esté a la altura (H-33).

8. **`FeedStatus.serviceDays` y la ventana del feed.** No es del buscador, pero se cruza con él:
   el razonamiento de que «siete días desde hoy» es la lista equivocada, con el caso real que lo
   demostró, es el tipo de comentario que justifica la política del proyecto de documentar el
   porqué en el código.

9. **La honestidad del pie de «Direcciones».** «Las direcciones las busca Apple Mapas. Tu
   ubicación no se envía: la búsqueda siempre se centra en Vigo» es cierto, verificable en el
   código, y está donde el usuario lo va a leer.

---

## 6. Plan sugerido

Cuatro tandas, ordenadas por valor entregado. Cada una es un commit coherente con su propia
verificación.

### Tanda A — Que el buscador encuentre lo que le piden
*El cambio que más se nota usando la app. Todo en `VigoCore`, todo testeable con `swift test`.*

- H-01 escapar `%`/`_` con `ESCAPE`, en `TextNormalization.likePattern`.
- H-10 plegar la puntuación en `searchFolded`. **Ojo: cambia `searchName`**, así que hay que
  forzar una reimportación (o migrar la columna en `v4`) y decirlo en `ESTADO.md`.
- H-09 emparejamiento por términos (`AND` de `LIKE`) con puntuación de relevancia en Swift.
- H-02, H-03, H-04, H-06 arreglar la rama numérica: recortar al `limit`, canonizar los ceros a la
  izquierda, ordenar el prefijo, y fusionar con la búsqueda por nombre en vez de cortarla.
- H-05 documentar (o restringir) los espacios interiores.

**Verificación.** `RepositoryTests` nuevos: `searchEscapesLikeWildcards`,
`searchMatchesTermsInAnyOrder`, `numericSearchRespectsLimit`,
`numericSearchIgnoresLeadingZeros`, `numericSearchAlsoMatchesNames`. En
`RealFeedIntegrationTests`, la batería de este informe convertida en tabla: `praza america`,
`avda florida`, `hospital povisa`, `urzaiz principe` deben devolver ≥1, y `%`, `_`, `praza_de`
deben devolver 0. Cinco mutaciones deliberadas, según el método de la Fase 3: quitar el `ESCAPE`,
volver a un único `LIKE`, no recortar la suma numérica, usar `digits` en vez de `String(code)`,
y reponer el `return` temprano de la rama numérica.

### Tanda B — Que la hoja no mienta, y que la ruta accesible no sea la peor
*Donde está el hallazgo de más valor. Mezcla `VigoCore` y app.*

- H-33 geocodificar el punto de «Elegir en el mapa», igual que la pulsación larga. **Primero**,
  porque de él dependen H-47 y la calidad de la Fase 12.
- H-44 extraer `SearchLayoutBuilder` a `VigoCore`, y con él resolver H-21, H-22, H-23 y H-28
  como casos de test en vez de como inspecciones.
- H-45 extraer `LineMatching` a `VigoCore`, y con él H-25, H-26, H-39.
- H-24 decidir qué hacer con «Líneas con servicio»: `stopIDs(routeID:)` y filas interactivas, o
  colapsar a 8 + «Ver todas».
- H-27 `contentShape` en `stopRow`. H-29 mensaje cuando el permiso está denegado.

**Verificación.** `SearchLayoutTests.swift` y `LineMatchingTests.swift` nuevos en
`VigoCore/Tests`, con las mutaciones listadas en cada hallazgo. Un test de `MapScreenModel` con
resolver stub para H-33. Comprobación en dispositivo, con la lista corta que este proyecto ya
usa: (a) elegir un punto en el mapa desde el buscador enseña el nombre de la calle; (b) con la
base vacía el buscador dice que no hay datos; (c) escribir «zz» no dice «no hay resultados»;
(d) el borde derecho de una fila de parada responde al toque; (e) con la ubicación denegada se
explica por qué no hay «Cerca de ti».

### Tanda C — Direcciones: el fichero que el propio código marca como el de más riesgo
*Todo en `MapKitAddressSearchService` y `AddressSearchModel`.*

- H-13 no sustituir `completions` cuando no hay continuación pendiente, y H-14 dejar el
  comentario diciendo la verdad.
- H-15 contador de generación en el `onCancel` — el plan B que el propio código propone.
- H-16 timeout, que es lo que convierte H-17 de cuelgue permanente en un error visible.
- H-18 serializar las resoluciones; el mínimo es aplicar el mismo `.disabled` al deslizamiento.
- H-19 identidad estable en `AddressSuggestion`. H-20 limpiar `failed` también al acertar.
- Al extraer la tabla de tokens a un tipo puro, este fichero deja de ser «el código de más riesgo
  y no cubierto por tests» — que es la frase que hoy encabeza el fichero.

**Verificación.** `AddressSearchModelTests` ampliado con `searchTimesOut` y
`concurrentResolutionsDoNotClobberEachOther`. Tests del tipo puro de tokens en `VigoCore`.
En dispositivo: escribir una dirección, esperar dos segundos sin tocar, y tocar una sugerencia —
hoy da error, después no; y tocar una fila y deslizar otra a la vez.

### Tanda D — Deuda del buscador único, y desbloquear la Fase 12
*Barata, y hay que hacerla antes de escribir la Fase 12, no después.*

- H-34 pasar el extremo de un trayecto guardado por `pick(_:)`, y anotar por qué `.explore` no.
- H-36 borrar `EndpointPickerSheet`; el buscador ya hace lo que hacía.
- H-35, H-37 usar las fábricas que ya existen (`MapPlace.savedPlace`, `savedEndpointInput`).
- H-38 derivar el `origin` de `savedEndpoint` del ancla, no del `placeID`.
- H-48 subir el redondeo a `Coordinate.rounded(toDecimals:)` en `VigoCore`.
- H-07 índice `COLLATE NOCASE` si la tanda A ha encarecido la consulta; si no, corregir el
  comentario y dejarlo.
- H-46 **corregir `PLAN-FASES-8-13.md` §12.1 y §12.4** antes de implementar: la lista de
  llamantes de `pick` no coincide con el código, `.pointOfInterest` no llega nunca por aquí, y
  hay que decidir si el punto de registro es `pick` o `MapNavigationState.select`, que es el
  embudo real de todo lo que acaba en una ficha.

**Verificación.** `MapPlaceTests.savedEndpointKeepsItsStop` y su mutación. La suite completa
verde. En dispositivo: elegir un lugar guardado como destino de un trayecto guardado, renombrar
el lugar, y comprobar que el nombre del extremo cambia — es decir, que quitar
`EndpointPickerSheet` no se ha llevado el enlace vivo por delante.

---

## 7. Fuera de alcance (dos líneas, como se pidió)

- `AppEnvironment.init` abre la base con `try!` y documenta por qué prefiere el crash; es una
  decisión consciente, pero un fichero corrupto en disco mata la app en el arranque sin ruta de
  recuperación, y no hay ningún test de ese camino.
- `BackgroundRefresh.swift:42` usa `nonisolated(unsafe)` para capturar la tarea de procesado; es
  el único escape de concurrencia estricta fuera de los dos `assumeIsolated` justificados del
  buscador, y no lleva justificación escrita.
