# Chinchilla 🐭✨

App nativa de limpieza y optimización para macOS, inspirada en [Mole](https://github.com/tw93/Mole) y CleanMyMac — pero honesta. Hecha en SwiftUI (Swift 6), compila **sin Xcode** (solo Command Line Tools) y no tiene ninguna dependencia externa.

> Como las chinchillas: se limpia con baños de polvo. 🛁

## Módulos

| Módulo | Qué hace |
|---|---|
| **Smart Scan** | Un clic desde el Dashboard o la barra de menú: combina limpieza segura + Docker + artefactos y muestra el total recuperable. |
| **Limpieza profunda** | Caches de apps y navegadores, logs, instaladores viejos, basura de desarrollo. Flujo escanear → revisar → limpiar, con *vista previa (dry-run) por defecto*. |
| **Desinstalador** | Desinstala apps junto con sus restos (Application Support, Preferences, Containers, LaunchAgents, etc.), todo a la Papelera. |
| **Espacio en disco** | Escaneo paralelo con `fts(3)`, drill-down por carpetas, treemap interactivo y buscador de archivos grandes (≥100 MB). |
| **Modo gaming** | Mantiene el Mac despierto (IOPMAssertion), detiene backups de Time Machine, cierra apps en segundo plano (con relanzado en un clic) y muestra CPU/GPU/presión de memoria/temperatura en un overlay flotante. **Sin humo**: no hay "purge" de RAM ni contador de FPS falso. |
| **Docker & Dev** | Estado del daemon, `docker system df`, prunes por categoría (seguro/profundo/build cache/volúmenes) y cazador de `node_modules`, `target`, `.venv` y `Pods` en proyectos viejos. |
| **Inicio** | Gestiona los launch agents que se cargan al iniciar sesión: apágalos/enciéndelos con un switch (reversible), y acceso directo a los Ítems de inicio de macOS. |
| **Duplicados** | Archivos idénticos (por contenido, SHA-256) en tus carpetas de usuario, agrupados por espacio desperdiciado; siempre conserva al menos una copia. |
| **Auto-clean semanal** | LaunchAgent propio que corre la app headless los domingos: limpia solo categorías seguras y notifica lo liberado. |
| **Widget de escritorio** | Anillo de espacio libre anclado al escritorio (todas las Spaces, detrás de tus ventanas), activable desde la barra de menú. |
| **Tab Saver** | Para acumuladores de pestañas: activa el Memory Saver de Chrome/Edge/Brave por política de usuario (las pestañas en segundo plano dejan de renderizar) y cierra pestañas duplicadas en Chrome y Safari. Reversible; se avisa que el navegador mostrará "Administrado por tu organización". |

También: ícono en la barra de menú con stats rápidas, onboarding en el primer arranque, y aviso de actualizaciones **pasivo** (una cápsula discreta en la toolbar cuando hay versión nueva en GitHub Releases — jamás un popup).

## Compilar y ejecutar

Requisitos: macOS 15+, Swift 6.1+ (Command Line Tools bastan). Corre en cualquier Mac: Apple Silicon (M1+, MacBook Neo con A18 Pro) e Intel — el release se compila universal (`CHINCHILLA_UNIVERSAL=1`).

```bash
./scripts/build-app.sh          # release → dist/Chinchilla.app (firma con tu Developer ID si existe)
cp -R dist/Chinchilla.app /Applications/   # "instalar" la nueva versión

./scripts/dev-run.sh            # build debug + abrir
swift test                      # tests (SafetyPolicy, walker, cleaner)
```

> ⚠️ Prueba las funciones de limpieza siempre desde el bundle (`dist/Chinchilla.app`), nunca con `swift run`: los permisos TCC (Full Disk Access) se asocian al bundle.

## Full Disk Access (opcional pero recomendado)

Sin FDA, Safari, la Papelera y otras rutas protegidas no se pueden medir ni limpiar (la app lo indica con un banner).

1. Ajustes del Sistema → Privacidad y seguridad → **Acceso total al disco**
2. `+` → selecciona `dist/Chinchilla.app`

**Nota sobre la firma:** el script firma ad-hoc por defecto, y macOS puede olvidar el permiso FDA en cada rebuild (cambia el cdhash). Para que sobreviva:

1. Acceso a Llaveros → Asistente de Certificados → Crear certificado…
2. Nombre: `Chinchilla Dev`, tipo: **Firma de código**
3. Recompila: el script detecta el certificado y lo usa automáticamente.

## Seguridad del borrado

- **Dry-run por defecto**: el botón dice "Previsualizar limpieza" hasta que apagues el switch.
- `SafetyPolicy` valida **cada path en el momento de borrar** (no solo al escanear): denylist absoluta (`/System`, iCloud Drive, Keychains, Mail, Fotos, `/private/var/…`), resolución de symlinks, raíces declaradas por regla, flags SIP/immutable.
- Por defecto se borra a la Papelera; solo los caches `safe` se eliminan directo.
- Todo queda registrado en `~/Library/Logs/Chinchilla/clean-history.jsonl`.

## Tab Guard (extensión de Chrome opcional)

En `extension/tabguard/` vive una extensión MV3 (JS puro, sin build) que agrega inteligencia **por pestaña**: duerme pestañas según tu inactividad real, hace *cold save* de las que llevan días sin tocar (guardadas y restaurables, nunca perdidas), y cuando activas el modo gaming duerme todas las pestañas de fondo y pausa sus videos. Habla con la app por Native Messaging (framing de 32 bits, host = el propio binario detectando `chrome-extension://` en argv). El manifest del conector es por usuario (cubre todos los perfiles); la extensión se carga una vez por perfil — la app te guía (Dashboard → Tab Saver → paso 3). Multi-perfil: las estadísticas agregan todas las conexiones activas.

## CLI

El mismo binario funciona como herramienta de línea de comandos, con la misma SafetyPolicy, guarda de apps abiertas y registro de auditoría que la GUI:

```bash
alias chinchilla="/Applications/Chinchilla.app/Contents/MacOS/Chinchilla"
chinchilla scan            # tabla de basura encontrada por categoría
chinchilla scan --json     # ídem, JSON por ítem (para scripts)
chinchilla clean           # dry-run de categorías seguras
chinchilla clean --real    # limpia de verdad
```

## Publicar una versión (DMG firmado y notarizado)

Requisitos una sola vez:

1. **Certificado**: "Developer ID Application" instalado en el Llavero (ya lo tienes ✓).
2. **Credenciales de notarización**:
   ```bash
   xcrun notarytool store-credentials chinchilla-notary \
     --apple-id TU_APPLE_ID --team-id 8457F927YF \
     --password CONTRASEÑA_ESPECÍFICA_DE_APP
   ```
   La contraseña específica de app se crea en https://account.apple.com → Inicio de sesión y seguridad.

Luego, cada release:

```bash
# 1. sube la versión en packaging/Info.plist (CFBundleShortVersionString y CFBundleVersion)
./scripts/release.sh
# → dist/Chinchilla-X.Y.Z.dmg  firmado, notarizado y con staple
```

El script verifica la firma como lo haría Gatekeeper (`spctl`) antes de terminar.

### Actualizaciones

Sin frameworks ni diálogos: la app consulta la API de GitHub Releases (máx. una vez al día, en silencio) y si hay versión nueva muestra una cápsula discreta en la toolbar que enlaza a la descarga. Publicar el release en GitHub (`gh release create vX.Y.Z dist/Chinchilla-X.Y.Z.dmg`) es todo lo que se necesita para que los usuarios lo vean.

## Arquitectura

```
Sources/
├── Chinchilla/    # SwiftUI: vistas + viewmodels (@Observable, @MainActor)
├── CleanCore/     # motor de limpieza: reglas, scanner, cleaner, SafetyPolicy
├── DiskScanKit/   # fts walker paralelo, treemap, tamaños asignados, artefactos
└── SystemKit/     # shell runner, docker, métricas (mach/sysctl/IOKit), permisos
```

Localizada en inglés y español (según el idioma del sistema).

## Licencia

[AGPL-3.0](LICENSE) — software libre: úsalo, modifícalo y compártelo bajo la misma licencia. Sin dependencias externas. Inspirada en [Mole](https://github.com/tw93/Mole) (GPL-3.0) sin reutilizar su código.

¿Te sirve Chinchilla? [Apóyala en GitHub Sponsors ♥](https://github.com/sponsors/SebastianMoyano)
