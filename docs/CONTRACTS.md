# Дополнение 0.4.0-preview.2

- План SchemaVersion=2; v1 только читается. Stamp v2 содержит Streams/ContentHash/TotalBytes, Attributes, CreationTicks/LastWriteTicks/AccessTicks и доступные Owner/Group/DACL в SDDL. LastAccess является изменяемым наблюдением: после чтения восстанавливается на копии, в SameStamp не участвует. SACL и произвольные дополнительные NTFS-метаданные не заявлены подтверждённо сохранёнными. Исполнитель preview выключен.
- Действия CompletePublishedMove и Recovery: отдельные планы и утверждение. Фазы неизменяемы; восстановление не перезаписывает источники. RecoveryResolved запрещает слепое повторение исходного плана.
- Approval содержит UTC expiry и, для автоматического согласования, bindings исходных разрешений. Partial требует AcceptPartial. Смена эффективных корней и контракта меняет PolicyHash.
- Preparation содержит известные counts, Limited/RemainingKnown, пути диагностики JSONL. Findings выдаются по 200. Неизвестный остаток — null.
- SnapshotIndex читает INDEX-1, INDEX-2 и INDEX-3; nodes.bin совместим. INDEX-3 хранит каталог диапазонов на диске. Импорт использует дисковые таблицы путей и счётчиков, внешнюю сортировку и общий ресурсный контекст.
- Duplicates/Changes содержат RowsFile/RowCount и первую страницу. RowsPage привязан к файлу результата в work; выбор дублей хранится отдельно между страницами. Внешние сортировки используют порции 48 MiB и слияние до 32 потоков.
- Worker принимает DataRoot/PolicyRoot/Isolated. Изолированный профиль требует обоих корней внутри tests. Отмена и бюджеты проверяются до 256 шагов/100 мс в управляемых циклах; блокирующий вызов ОС этим не ограничен.
- storage-catalog v2 сохраняет измеренные логические размеры файлов и время сверки. Во время записи задание учитывает прирост только в своих зарегистрированных областях. У рабочих каталогов есть метка владельца, а причины новых планов копируются в реестр решений. Обслуживание технических файлов выключено по умолчанию.

Ниже сохранён контракт исходной версии; это дополнение имеет приоритет для preview.

---

# SmartClean contracts, schema 1

InventoryProvider returns observedUtc, physical disks, partitions, volumes and warnings. Unknown hardware information stays unknown. Volume IDs are distinct from mount paths/drive letters.

ScannerAdapter accepts one existing filesystem directory, output location, cancellation and timeout. It must not modify scanned content, inherit the installed application's settings, follow directory links, invoke a browser or expose cleanup actions. Capabilities declare allocated size, identity, error telemetry, cancellation/export and resume separately. Current adapter: pinned WinDirStat 2.9.3; error telemetry and partial-on-cancel are unavailable.

Snapshot manifest: SchemaVersion, AppVersion, SnapshotId, HostId (local hash), Root, VolumeId, Elevated, interval StartedUtc/FinishedUtc, Engine/EngineVersion/EngineSchema, Metric, LinkPolicy, ExcludedRoots, Coverage, Status, HasIndex, Warnings, Failure, Totals, Measurements. A scan is an observation interval, not an atomic filesystem snapshot. SnapshotDirectory is a runtime locator, not saved into the manifest. Status partial with HasIndex true means finished engine export with unverified coverage; failed/cancelled trees are never opened.

SnapshotStore layout: snapshots/id/manifest.json, inventory.json, engine.csv, nodes.bin, index.bin; history/events.jsonl. DataRoot is always excluded from scans. Current limits stop creation instead of silently removing history. Only the own-report deletion operation can remove selected generated outputs. Manifest writes use same-directory temp and rename. Binary index is published before HasIndex; failure cannot advertise a complete index. Crash consistency against power loss is not guaranteed.

nodes.bin: UTF-8 BinaryWriter records. Each node is addressed by its byte offset. Record: Int64 ParentId, Byte Kind (1 directory, 2 file, 3 excluded link), Int64 LogicalBytes, Int64 AllocatedBytes, Int64 UniqueAllocatedBytes, Int64 Files, Int64 Folders, String Path, String Attributes, String Identity. Unknown unique allocation is -1. Directory totals are aggregated from file entries, without counting link targets. RootId=0. index.bin: string SMARTCLEAN-INDEX-1, Int32 directory count, then per directory Int64 node offset, Int32 child count, child Int64 offsets. This is an internal format; new incompatible layouts require a new schema.

Unique allocation removes repeated nonzero export file IDs within one volume/scope. It is not a deletion saving estimate. Unknown IDs make the aggregate unknown; they do not silently become unique. Logical and allocated-per-path totals preserve separate semantics. Exports are validated for language, fields, nonnegative numbers, parent order and scope; unrelated synthetic records are skipped.

DiffService refuses different host/volume/scope/engine version/elevation/metric/link policy/exclusions. It currently compares directory aggregates, not individual file rename histories. Missing observations are ambiguous in best-effort scans. Changes at ancestor and descendant levels overlap and must not be summed. Process attribution is outside v0.1.

Future CleanupRule: id/version, category, owner evidence, target scope, explanation, consequences, preconditions, exclusions. Planner produces a reviewable immutable candidate plan. Executor revalidates identity/path/reparse status, running application constraints and matching scoped approval immediately before changing anything. New expanded rule versions do not silently inherit consent. These contracts are reserved; no cleanup executor is shipped in v0.1.

## Analysis/reporting added in 0.2

Analysis.ps1 reads the existing index, not the scanned filesystem tree. A bounded frontier expands heavy container directories, then reports up to 25 disjoint observations over 256 MiB; it is not a volume accounting sum. Inspect reads the index sequentially to retain bounded top-files, link nodes and narrowly matched candidate directories. Candidate recognition is advisory and Approved is always false in this release. System-directory matches and zero-size candidates are excluded from the user candidate list.

Reports live outside immutable snapshots at reports/snapshotId: summary.md, analysis.json, links.csv. AnalysisVersion controls derived-report cache compatibility. The report records scan time and generation time separately. NativeLinks reads FSCTL_GET_REPARSE_POINT on an OPEN_REPARSE_POINT handle, with no write access and no traversal. Only symbolic-link/mount-point buffers are interpreted, with bounds checks; unknown types and Win32 errors remain explicit. Destination observation is current metadata, not reconstructed historical evidence. Foreign-host snapshots do not trigger misleading local target queries.

Primary references for native metadata interpretation: [Microsoft FSCTL_GET_REPARSE_POINT](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-fsctl_get_reparse_point), [REPARSE_DATA_BUFFER](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer).
