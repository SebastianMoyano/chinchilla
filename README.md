# Chinchilla

Limpieza y mantenimiento de macOS, en una app nativa. SwiftUI y Swift 6, sin dependencias externas, compila sin Xcode.

**[Descargar la última versión](https://github.com/SebastianMoyano/chinchilla/releases/latest)** · macOS 14+ · Apple Silicon e Intel · firmada y notarizada

---

## Por qué existe

Administro los Mac de un colegio. La tarea que más se repite es la más aburrida: equipos que se llenan, se ponen lentos y nadie sabe por qué. Revisarlos uno por uno a mano no escala, y las herramientas comerciales del rubro cuestan por licencia y además exageran — inventan gigabytes, prometen acelerar cosas que no aceleran y venden el miedo antes que el arreglo.

Quería algo que pudiera dejar instalado y que un profesor pudiera abrir sin saber qué es una caché.

También escribo software, así que la máquina de trabajo tiene otro problema distinto: imágenes de Docker, `node_modules` de proyectos que abandoné, artefactos de compilación. Eso no aparece en ningún limpiador comercial porque no es su público. Como la app ya recorría el disco, agregarlo era barato. El mismo criterio explica el resto: cada módulo entró porque yo tenía ese problema y ya existía la maquinaria para resolverlo.

## En qué se inspira

En [Mole](https://github.com/tw93/Mole), de tw93: la idea de un limpiador de macOS libre, rápido y sin adornos. Chinchilla no reutiliza su código — está escrita desde cero en Swift — pero le debe el enfoque.

El nombre sigue la broma: las chinchillas se limpian revolcándose en polvo.

## Qué hace

| | |
|---|---|
| **Dashboard** | Smart Scan: un clic combina limpieza segura, Docker y artefactos, y muestra el total recuperable. |
| **Limpieza profunda** | Cachés, logs, instaladores viejos, basura de desarrollo. Escanear → revisar → limpiar, con vista previa por defecto. |
| **Desinstalador** | Saca la app y sus restos: Application Support, Preferences, Containers, LaunchAgents. Todo a la Papelera. |
| **Espacio en disco** | Recorrido paralelo con `fts(3)`, treemap interactivo, buscador de archivos grandes. |
| **Salud** | SMART del disco, ciclos y capacidad de la batería, procesos zombis, gestión MDM, tiempo desde el último reinicio. Botiquín de reparaciones y control de servicios de Homebrew. |
| **Modo juego** | Mantiene el Mac despierto, pausa Time Machine, congela apps de fondo (reversible) y muestra CPU, GPU, memoria y temperatura en un overlay. |
| **Modo diario** | El hermano del anterior para el uso de todos los días: pestañas que duermen, limpieza semanal programada y vigilancia de la presión de memoria. |
| **Docker y dev** | Estado del daemon, `docker system df`, prunes por categoría, y cazador de `node_modules`, `target`, `.venv` y `Pods` en proyectos viejos. |
| **Inicio** | Los launch agents que se cargan al iniciar sesión, con interruptor reversible. |
| **Cast** | Envía archivos al televisor y duplica la pantalla por Google Cast, DLNA o FCast. Ver abajo. |
| **Duplicados** | Archivos idénticos por contenido (SHA-256), agrupados por espacio desperdiciado. Siempre conserva una copia. |
| **Doctor de memoria** | Qué está consumiendo la RAM, en lenguaje llano: agrupa los procesos ayudantes bajo la app que los lanzó. |

Además: icono en la barra de menús que muestra el modo activo, widget de espacio libre en el escritorio, limpieza automática semanal, y extensión opcional de Chrome para gestionar pestañas.

## Lo que deliberadamente no hace

Esto es la mitad del punto, así que va explícito:

- **No libera RAM.** El "purge" de memoria no acelera nada en macOS moderno; el sistema ya administra eso mejor que cualquier app.
- **No muestra FPS inventados** ni promete cuadros por segundo que no puede entregar.
- **No apaga Spotlight** ni servicios del sistema para simular mejoras.
- **No borra idiomas** de las apps: rompe la firma y ahorra una miseria.
- **No pide contraseña de administrador** salvo para dos reparaciones puntuales, y lo dice antes.
- **No infla las cifras.** Lo que reporta es lo que se libera.

Cada optimización que sí incluye es real, reversible y sin root.

## Casting y espejo de pantalla

Empezó como un pedido simple —mandar un video al televisor sin instalar nada— y terminó implementando tres protocolos desde cero: Google Cast v2 (protobuf a mano sobre TLS), DLNA/UPnP y FCast.

El espejo de pantalla usa el receptor de duplicación que traen los dispositivos Chromecast, el mismo que usa Chrome para "Transmitir escritorio": nada que instalar en el televisor y **menos de medio segundo de retraso**, contra los dos o tres segundos del reproductor multimedia normal. Captura con ScreenCaptureKit, codifica H.264 por hardware con VideoToolbox y Opus para el audio, y transporta RTP cifrado con AES-128-CTR, con retransmisión y reportes RTCP.

Si un televisor rechaza ese camino, cae al anterior y lo dice en pantalla.

## Seguridad al borrar

- **Vista previa por defecto.** El botón dice "Previsualizar limpieza" hasta que apagues el interruptor.
- `SafetyPolicy` valida **cada ruta en el momento de borrar**, no solo al escanear: lista negra absoluta (`/System`, iCloud Drive, llaveros, Mail, Fotos, `/private/var/…`), resolución de enlaces simbólicos, raíces declaradas por regla, banderas SIP e inmutable.
- Se borra a la Papelera. Solo las cachés clasificadas como seguras se eliminan directo.
- Todo queda registrado en `~/Library/Logs/Chinchilla/clean-history.jsonl`.

## Línea de comandos

El mismo binario es una herramienta de consola, con la misma política de seguridad y el mismo registro que la interfaz:

```bash
alias chinchilla="/Applications/Chinchilla.app/Contents/MacOS/Chinchilla"

chinchilla scan            # basura encontrada, por categoría
chinchilla scan --json     # lo mismo en JSON, para scripts
chinchilla clean           # vista previa de las categorías seguras
chinchilla clean --real    # limpia de verdad
```

Útil justamente para el caso del colegio: se puede correr por SSH o desde una tarea programada.

## Compilar

Requiere macOS 14+ y Swift 6.1+. Las Command Line Tools bastan — no hace falta Xcode.

```bash
./scripts/build-app.sh                      # → dist/Chinchilla.app
cp -R dist/Chinchilla.app /Applications/
./scripts/dev-run.sh                        # build de depuración y abrir
swift test
```

Prueba siempre desde el bundle, nunca con `swift run`: los permisos TCC (Acceso total al disco, Grabación de pantalla) se asocian al bundle, no al binario suelto.

### Acceso total al disco

Sin él no se pueden medir ni limpiar Safari, la Papelera y otras rutas protegidas; la app lo avisa con un banner. Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco → `+` → `Chinchilla.app`.

Si compilas tú mismo, la firma ad-hoc cambia en cada build y macOS olvida el permiso. Para evitarlo, crea un certificado de firma de código llamado `Chinchilla Dev` en Acceso a Llaveros; el script lo detecta y lo usa.

### Publicar una versión

```bash
# subir la versión en packaging/Info.plist
NOTARY_PROFILE="tu-perfil" ./scripts/release.sh    # → DMG firmado, notarizado y con staple
gh release create vX.Y.Z dist/Chinchilla-X.Y.Z.dmg
```

Requiere un certificado "Developer ID Application" y credenciales de notarización guardadas con `xcrun notarytool store-credentials`. El script verifica la firma como lo haría Gatekeeper antes de terminar.

### Actualizaciones

Sin frameworks ni diálogos. La app consulta la API de GitHub Releases una vez al día, en silencio, y si hay versión nueva muestra una cápsula discreta en la barra de herramientas. Nunca un popup: publicar el release es todo lo que hace falta.

## Flota: `history` y `status` (Fase 1)

Dos comandos pensados para revisar muchos Macs por SSH en vez de sentarse en cada uno:

```bash
chinchilla history                  # últimas 20 limpiezas: fecha, liberado, ítems, fallos
chinchilla history --limit 100      # o --limit=100
chinchilla history --json           # las entradas crudas del log, como array JSON

chinchilla status                   # tabla compacta: disco, memoria, uptime, batería, SMART, MDM
chinchilla status --json            # objeto único y estable (camelCase) para scripts
```

`history` lee `~/Library/Logs/Chinchilla/clean-history.jsonl` — el log de auditoría que la app siempre escribió y que nadie podía leer. Si el archivo no existe la historia está vacía (no es un error), y las líneas truncadas o corruptas se saltan: un JSONL puede quedar a medio escribir si mataron la app durante el append.

`status` no puede colgarse: las sondas externas (`diskutil`, `ioreg`, `profiles`) corren en paralelo con timeout de 5 s cada una, y el comando entero tiene un tope de 20 s. En `--json`, los campos opcionales (`batteryCycles`, `smartStatus`, `mdmEnrolled`) se omiten cuando este Mac no puede responder — nunca se rellenan con ceros.

```json
{
  "freeBytes": 12803244032, "totalBytes": 245107195904,
  "memoryUsedBytes": 6383763456, "memoryTotalBytes": 8589934592,
  "memoryPressure": "warning", "uptimeDays": 29,
  "bootDate": "2026-07-05T12:40:29Z",
  "batteryCycles": 228, "batteryHealthPercent": 86,
  "zombieCount": 0, "mdmEnrolled": false, "smartStatus": "Verified"
}
```

## Instalar con Homebrew (tap propio)

En `packaging/homebrew/chinchilla.rb` está la plantilla del cask. Para publicarlo:

1. Crea un repo público `SebastianMoyano/homebrew-chinchilla` (el prefijo `homebrew-` es obligatorio; el tap se llamará `SebastianMoyano/chinchilla`).
2. Copia la plantilla a `Casks/chinchilla.rb` en ese repo.
3. En cada release, reemplaza los dos valores marcados como `PLACEHOLDER`:

   ```bash
   VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
   shasum -a 256 "dist/Chinchilla-$VERSION.dmg"        # sha256 del DMG que subiste al release
   # o, si ya está publicado:
   curl -sL "https://github.com/SebastianMoyano/chinchilla/releases/download/v$VERSION/Chinchilla-$VERSION.dmg" | shasum -a 256
   ```

4. Commit y push. Los usuarios instalan con:

   ```bash
   brew tap SebastianMoyano/chinchilla
   brew install --cask chinchilla
   ```

El cask instala `Chinchilla.app` en `/Applications` y enlaza el binario como `chinchilla`, así que el CLI queda en el `PATH` sin alias. Antes de subir cambios al tap conviene correr `brew audit --cask --strict chinchilla` y `brew install --cask ./Casks/chinchilla.rb` en local.

> El DMG debe estar firmado y notarizado (`./scripts/release.sh`); Homebrew no evita Gatekeeper.

## Arquitectura

```
Sources/
├── Chinchilla/     # SwiftUI: vistas y viewmodels (@Observable, @MainActor)
├── CleanCore/      # motor de limpieza: reglas, scanner, cleaner, SafetyPolicy
├── DiskScanKit/    # recorrido fts paralelo, treemap, tamaños asignados
├── SystemKit/      # shell runner, Docker, métricas (mach/sysctl/IOKit), permisos
├── CastKit/        # Google Cast, DLNA, FCast, captura, RTP, servidor HTTP
└── StreamHostKit/  # host compatible con Moonlight (emparejamiento)
```

Dos reglas que costaron caro y que conviene conocer antes de tocar el código:

1. **Todo trabajo bloqueante va por `Blocking.run`**, nunca directo en un `Task`. El pool cooperativo de Swift tiene un carril por núcleo; un escaneo lanzado ahí ahoga el resto de la app.
2. **La interfaz nunca espera a un proceso externo sin plazo.** Se renderiza con datos locales al instante, las sondas corren en paralelo con tiempos límite cortos y los resultados se rellenan después.

Interfaz en español e inglés, según el idioma del sistema.

## Licencia

[AGPL-3.0](LICENSE). Software libre: úsalo, modifícalo y compártelo bajo la misma licencia.

Si te resulta útil, puedes [apoyarlo en GitHub Sponsors](https://github.com/sponsors/SebastianMoyano).
