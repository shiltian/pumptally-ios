# PumpTally 1.6 release

Version **1.6**, build **16**, minimum **iOS 17.0**. Use the **PumpTally** scheme and **Release** configuration, bundle `me.tianshilei.fuelio`. SyncQA, CloudKitProtocol and Testing are development targets/configurations and must not be distributed as the app.

## App Store release notes

### English

- Faster history, charts and statistics for large fuel logs.
- Improved number entry, record validation and CSV imports.
- Improved iCloud sync review, recovery and error handling.
- Updated app icon and Spanish and Simplified Chinese translations.
- Reliability fixes across supported iOS versions, including iOS 17.

### Spanish

- Historial, gráficos y estadísticas más rápidos para registros extensos.
- Mejoras en la introducción de números, la validación de registros y la importación de CSV.
- Mejoras en la revisión de cambios, la recuperación y la gestión de errores de iCloud.
- Icono actualizado y traducciones al español y al chino simplificado mejoradas.
- Correcciones de fiabilidad en las versiones de iOS compatibles, incluido iOS 17.

### Simplified Chinese

- 优化长时间加油记录的历史、图表和统计加载速度。
- 改进数字输入、记录校验和 CSV 导入。
- 改进 iCloud 同步变更审核、恢复和错误处理。
- 更新应用图标，并完善西班牙语和简体中文翻译。
- 修复各受支持 iOS 版本上的稳定性问题，包括 iOS 17。

## Completed verification

- The same 541 unit/integration and 43 UI cases passed on iOS 17.5, 18.6, 26.5 and 27.2 across full runs and focused reruns. Optimized persistence and Thread Sanitizer checks also passed; [development notes](DEVELOPMENT.md) retain the exact scope and diagnostics.
- All 20 installed-app upgrade paths from v1.1–v1.5 passed: 15 directly UI-populated cases and five explicitly restored historical-state cases on iOS 17. Each preserved 801 original records' business values through migration, editing, saving and reopening. See [upgrade results and binary-provenance limitations](UPGRADE_TESTING.md).
- Nine isolated native CloudKit protocol tests passed on the physical 17 Pro Max.
- Two-device Development sync passed create/read, reverse editing, record creation, offline edits retained through reopening, reconnect convergence, record deletion and vehicle/child deletion. Raw stored numbers, identities and ownership were checked. v1.5 read the current data accurately; its note edit reached the current app according to the user. See [device results](DEVICE_SYNC_TESTING.md) for evidence and the last edit's narrower scope.
- The final QA setup passed 34 focused startup/sync runtime tests, the ordinary Release build and production source/binary isolation checks. No stored models or shipping bootstrap changed during release preparation.

Device testing is paused at the user's request. Remaining mixed-version numeric writes/deletes, physical Files/CSV and account-transition scenarios are deferred. This checklist does not present them as completed tests. No new full test matrix is required merely for these documentation changes.

## Data compatibility

Retain historical schemas and the explicit migration path through V6. Keep the original CloudKit record types, identifiers, scalar fields and storage-unit meaning. Bulk iCloud replacement remains disabled because unknown old clients cannot honor the generation guard. Do not reenable it for this release.

CSV is an exchange format and does not include the complete retained inbox/recovery state. Preserve an appropriate backup before any real-user data operation. The device checks used only synthetic stores in a separate Development container.

## Distribution steps

1. Verify and deploy the **additive** production CloudKit schema in `iCloud.me.tianshilei.fuelio` before running the new build through TestFlight. Preserve every existing field/type. Required additions are listed below and in [development notes](DEVELOPMENT.md#production-cloudkit-schema). The isolated probe/QA container is a different container.
2. Archive **PumpTally / Release**. A connected phone is unnecessary; use a generic iOS archive destination. Confirm version 1.6/build 16, minimum iOS 17.0, shipping bundle identifier and absence of QA/test code in the archived app.
3. Use Xcode Organizer to validate and distribute the archive to App Store Connect. Check the distribution-signed app's CloudKit entitlements: container `iCloud.me.tianshilei.fuelio`, environment **Production**. The archive's development signature before export is not the final distribution signature.
4. Complete a TestFlight smoke check against the deployed production schema, then select the intended public release timing in App Store Connect. Record any acceptance of the deferred device scenarios explicitly.
5. Use the localized release notes above. Review the App Store version, privacy answers, screenshots and support links; this release adds no analytics or tracking dependency.

| Record type | Additive fields |
| --- | --- |
| `PumpTallySyncControl` | `version` (Int64), `generation`, `phase`, `transaction` (String) |
| `Vehicle` | `displayUnitSystemRaw`, `syncGenerationV1` (String) |
| `FuelingRecord` | `measurementsV1` (Bytes), `syncGenerationV1` (String) |

Production schema deployment, App Store Connect upload and public release are pending. Preparing the repository or building an archive performs none of those operations.
