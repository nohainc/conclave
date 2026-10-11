import 'package:conclave_design/conclave_design.dart';
import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:flutter/material.dart';

/// Management-only projection of the Service-owned catalog. No discovery or
/// execution is performed by this view.
class WorkerModelCatalogView extends StatelessWidget {
  const WorkerModelCatalogView(
      {super.key,
      required this.workerId,
      required this.workerName,
      required this.catalog,
      this.loading = false});
  final String workerId, workerName;
  final DiscoveredModelCatalog? catalog;
  final bool loading;
  @override
  Widget build(BuildContext context) => ModelEffortSelector(
        showWorker: false,
        readOnly: true,
        loading: loading,
        value: ExecutionSelection(worker: workerId),
        catalog: ExecutionSelectionCatalog([
          WorkerSelectionCapability(
            id: workerId,
            name: workerName,
            state: catalog == null
                ? CapabilityState.unavailable
                : catalog!.stale
                    ? CapabilityState.stale
                    : CapabilityState.ready,
            models: [
              for (final model in catalog?.models ?? const <DiscoveredModel>[])
                ExecutionModelCapability(
                    id: model.id,
                    name: model.name,
                    efforts: model.supportedReasoningEfforts,
                    defaultEffort: model.defaultReasoningEffort,
                    selectionMode: model.selectionMode,
                    status: model.status)
            ],
          )
        ]),
      );
}
