# Windows ISO Offline Test

GitHub Actions workflow for downloading a Windows ISO artifact and validating
the final offline image without installing Windows.

The workflow:

1. Downloads a ZIP archive from a direct URL or a GitHub Actions run/artifact URL.
2. Verifies and extracts the archive.
3. Validates the ISO checksum when one is supplied or included in the archive.
4. Mounts the ISO and selected `install.wim` or `install.esd` image read-only.
5. Loads the offline `SYSTEM` hive.
6. Resolves `Select\Current` to the future active `ControlSetXXX`.
7. Checks the Windows Low Latency Profile feature flag `58989092`.
8. Uploads Markdown and JSON reports.

## Run The Workflow

Open **Actions** -> **Test Windows ISO** -> **Run workflow**.

Inputs:

- `archive_url`: direct ZIP URL, GitHub Actions run URL, or artifact URL.
- `artifact_name`: required only when a run contains multiple artifacts.
- `iso_pattern`: ISO filename pattern; default `*.iso`.
- `image_index`: image index to inspect; default `1`.
- `expected_sha256`: optional expected ISO SHA256.
- `require_low_latency_profile`: fail when the feature definition is absent; default `true`.

For temporary signed URLs, store the URL in the repository secret
`ISO_ARCHIVE_URL` and leave `archive_url` empty. This avoids placing the signed
URL in workflow inputs.

For a GitHub Actions run or artifact URL, add a fine-grained personal access
token to the repository secret `SOURCE_GITHUB_TOKEN`. The token needs Actions
read access to the source repository. Direct downloadable ZIP URLs do not need
this token.

Examples of supported GitHub URLs:

```text
https://github.com/OWNER/REPOSITORY/actions/runs/RUN_ID
https://github.com/OWNER/REPOSITORY/actions/runs/RUN_ID/artifacts/ARTIFACT_ID
```

## Low Latency Profile Rules

For each offline `ControlSetXXX`, the test checks:

```text
Control\FeatureManagement\Definitions\Associations\1213986446
Control\FeatureManagement\Overrides\0\1213986446
Control\FeatureManagement\Overrides\8\1213986446
```

The image-default state is reported for diagnostics. Regardless of whether
`ImageDefault (0)` is already enabled, `User (8)` must contain five DWORD
values so the result does not depend on rollout state after installation:

```text
EnabledState        = 2
EnabledStateOptions = 0
Variant             = 0
VariantPayload      = 0
VariantPayloadKind  = 0
```

The workflow also confirms that `Select\Current` references an existing,
validated `ControlSetXXX`.
