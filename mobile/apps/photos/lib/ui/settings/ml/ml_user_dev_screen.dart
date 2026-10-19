import "dart:async";

import "package:ente_components/ente_components.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/service_locator.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/settings/settings_grouped_card.dart";
import "package:photos/utils/dialog_util.dart";

final Logger _logger = Logger("MLUserDeveloperOptions");

class MLUserDeveloperOptions extends StatefulWidget {
  final bool mlIsEnabled;
  const MLUserDeveloperOptions({super.key, this.mlIsEnabled = true});

  @override
  State<MLUserDeveloperOptions> createState() => _MLUserDeveloperOptionsState();
}

class _MLUserDeveloperOptionsState extends State<MLUserDeveloperOptions> {
  late int _autoUnnamedPersonPhotoThreshold;

  @override
  void initState() {
    super.initState();
    _autoUnnamedPersonPhotoThreshold =
        localSettings.autoUnnamedPersonPhotoThreshold;
  }

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
        if (widget.mlIsEnabled) ...[
          const SizedBox(height: 24),
          SettingsGroupedCard(
            children: [_buildAutoUnnamedThresholdItem(context)],
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildAutoUnnamedThresholdItem(BuildContext context) {
    final textTheme = getEnteTextTheme(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Auto-create unnamed people", style: textTheme.smallBold),
          const SizedBox(height: 4),
          Text(
            "Create an unnamed person for an unassigned face cluster after it appears in this many distinct uploaded photos. Applied on the next normal ML run or manual clustering command. Set to 0 to disable.",
            style: textTheme.miniMuted,
          ),
          Slider(
            value: _autoUnnamedPersonPhotoThreshold.toDouble(),
            min: 0,
            max: 100,
            divisions: 100,
            label: _autoUnnamedPersonPhotoThreshold == 0
                ? "Off"
                : "$_autoUnnamedPersonPhotoThreshold photos",
            onChanged: (value) {
              final threshold = value.round();
              setState(() => _autoUnnamedPersonPhotoThreshold = threshold);
              unawaited(
                localSettings.setAutoUnnamedPersonPhotoThreshold(threshold),
              );
            },
          ),
          Text(
            _autoUnnamedPersonPhotoThreshold == 0
                ? "Current: Off"
                : "Current: $_autoUnnamedPersonPhotoThreshold photos",
            style: textTheme.miniMuted,
          ),
          const SizedBox(height: 4),
          Text("Default: 10 photos", style: textTheme.miniMuted),
        ],
      ),
    );
  }
}
