Drop your Windows 11 ISOs in this folder.

Expected filenames (referenced by config\upgrade.config.json):
  Win11_Enterprise.iso       - Non-LTSC target (Win11 Enterprise/Pro, any current build)
  Win11_Enterprise_LTSC.iso  - LTSC target (Win11 IoT Enterprise LTSC 2024 or newer)

You can rename these as long as you update config\upgrade.config.json to match.

ISOs are .gitignored - they are never committed to git. Place them on the
network share alongside this folder so endpoints can read them.
