import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/service_locator.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/models/button_type.dart";
import "package:photos/ui/settings/ml/ml_clustering_thresholds.dart";
import "package:photos/ui/settings/ml/ml_debug_actions.dart";
import "package:photos/utils/dialog_util.dart";

final Logger _logger = Logger("MLUserDeveloperOptions");

class MLUserDeveloperOptions extends StatefulWidget {
  final bool mlIsEnabled;
  const MLUserDeveloperOptions({super.key, this.mlIsEnabled = true});

  @override
  State<MLUserDeveloperOptions> createState() => _MLUserDeveloperOptionsState();
}

class _MLUserDeveloperOptionsState extends State<MLUserDeveloperOptions> {
  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: "ML debug options",
      children: [
        Text(
          "Only use if you know what you're doing",
          textAlign: TextAlign.left,
          style: getEnteTextTheme(
            context,
          ).body.copyWith(color: getEnteColorScheme(context).textMuted),
        ),
        const SizedBox(height: 48),
        widget.mlIsEnabled
            ? MenuComponent(
                title: "Show ML debug options",
                trailing: ToggleSwitchComponent.async(
                  value: () => localSettings.showMLDebugOptions,
                  onChanged: () async {
                    try {
                      await localSettings.setShowMLDebugOptions(
                        !localSettings.showMLDebugOptions,
                      );
                      if (mounted) setState(() {});
                    } catch (e, s) {
                      _logger.warning("ML debug options toggle failed", e, s);
                      if (!context.mounted) return;
                      await showGenericErrorDialog(context: context, error: e);
                    }
                  },
                ),
              )
            : const SizedBox.shrink(),
        widget.mlIsEnabled ? const SizedBox(height: 24) : const SizedBox(),
        widget.mlIsEnabled
            ? ButtonWidget(
                buttonType: ButtonType.neutral,
                labelText: "Purge empty indices",
                onTap: () async {
                  await purgeEmptyMLIndices(context);
                },
              )
            : const SizedBox(),
        widget.mlIsEnabled ? const SizedBox(height: 24) : const SizedBox(),
        widget.mlIsEnabled
            ? ButtonWidget(
                buttonType: ButtonType.neutral,
                labelText: "Reset all local ML",
                onTap: () async {
                  await resetAllLocalML(context);
                },
              )
            : const SizedBox(),
        widget.mlIsEnabled ? const SizedBox(height: 24) : const SizedBox(),
        widget.mlIsEnabled
            ? MenuComponent(
                title: "Remote fetch",
                trailing: ToggleSwitchComponent.async(
                  value: () => localSettings.remoteFetchEnabled,
                  onChanged: () async {
                    try {
                      await localSettings.toggleRemoteFetch();
                      _logger.info(
                        'Remote fetch is turned ${localSettings.remoteFetchEnabled ? 'on' : 'off'}',
                      );
                      if (mounted) {
                        setState(() {});
                      }
                    } catch (e, s) {
                      _logger.warning('Remote fetch toggle failed ', e, s);
                      if (!context.mounted) return;
                      await showGenericErrorDialog(context: context, error: e);
                    }
                  },
                ),
              )
            : const SizedBox(),
        widget.mlIsEnabled
            ? const SizedBox(height: 24)
            : const SizedBox.shrink(),
        widget.mlIsEnabled
            ? MenuComponent(
                title: "Run ML on interactions",
                trailing: ToggleSwitchComponent.async(
                  value: () => localSettings.runMLDuringInteractionOverride,
                  onChanged: () async {
                    try {
                      final enabled =
                          !localSettings.runMLDuringInteractionOverride;
                      await computeController.setMLInteractionOverride(
                        turnOn: enabled,
                      );
                      _logger.info(
                        'run ML during interaction is turned ${enabled ? 'on' : 'off'}',
                      );
                      if (mounted) {
                        setState(() {});
                      }
                    } catch (e, s) {
                      _logger.warning(
                        'run ML during interaction toggle failed ',
                        e,
                        s,
                      );
                      if (!context.mounted) return;
                      await showGenericErrorDialog(context: context, error: e);
                    }
                  },
                ),
              )
            : const SizedBox.shrink(),
        widget.mlIsEnabled
            ? const SizedBox(height: 24)
            : const SizedBox.shrink(),
        MLClusteringThresholds(visible: widget.mlIsEnabled),
        const SizedBox(height: 12),
      ],
    );
  }
}
