# Publicar el cask de Homebrew

Notas de mantenimiento — no forman parte de la documentación pública.
`chinchilla.rb` en esta carpeta es la plantilla del cask.

## Primera vez

1. Crear un repo público `SebastianMoyano/homebrew-chinchilla` (el prefijo
   `homebrew-` es obligatorio; el tap se llamará `SebastianMoyano/chinchilla`).
2. Copiar la plantilla a `Casks/chinchilla.rb` en ese repo.
3. Cuando el tap exista, añadir al README principal la sección de instalación:

   ```bash
   brew tap SebastianMoyano/chinchilla
   brew install --cask chinchilla
   ```

## En cada release

Reemplazar los dos valores marcados como `PLACEHOLDER` en el cask:

```bash
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist)
shasum -a 256 "dist/Chinchilla-$VERSION.dmg"        # sha256 del DMG subido al release
# o, si ya está publicado:
curl -sL "https://github.com/SebastianMoyano/chinchilla/releases/download/v$VERSION/Chinchilla-$VERSION.dmg" | shasum -a 256
```

Después, commit y push en el repo del tap.

## Verificación antes de subir cambios al tap

```bash
brew audit --cask --strict chinchilla
brew install --cask ./Casks/chinchilla.rb
```

El cask instala `Chinchilla.app` en `/Applications` y enlaza el binario como
`chinchilla`, con lo que el CLI queda en el `PATH` sin alias.

El DMG debe estar firmado y notarizado (`./scripts/release.sh`); Homebrew no
evita Gatekeeper.
