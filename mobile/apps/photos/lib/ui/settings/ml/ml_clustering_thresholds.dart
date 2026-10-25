import "dart:async";

import "package:flutter/material.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/machine_learning/face_ml/face_clustering/face_clustering_service.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/settings/settings_grouped_card.dart";
import "package:photos/ui/components/toggle_switch_widget.dart";

class MLClusteringThresholds extends StatefulWidget {
  const MLClusteringThresholds({super.key, this.visible = true});

  final bool visible;

  @override
  State<MLClusteringThresholds> createState() => _MLClusteringThresholdsState();
}

class _MLClusteringThresholdsState extends State<MLClusteringThresholds> {
  static const double _autoMergeMin = 0.01;
  static const double _autoMergeMax = 0.35;
  static const double _clusteringMin = 0.10;
  static const double _clusteringMax = 0.35;
  static const double _thresholdStep = 0.01;

  late double _autoMergeThreshold;
  late double _defaultClusteringDistance;
  late bool _persistAutoMergeThreshold;
  late bool _persistDefaultClusteringDistance;

  @override
  void initState() {
    super.initState();
    final savedAutoMerge = localSettings.autoMergeThresholdOverride;
    _persistAutoMergeThreshold = true;
    _autoMergeThreshold = _clampThreshold(
      savedAutoMerge ?? PersonService.autoMergeThreshold,
      _autoMergeMin,
      _autoMergeMax,
    );
    PersonService.autoMergeThreshold = _autoMergeThreshold;
    if (savedAutoMerge != null) {
      unawaited(
        localSettings.setAutoMergeThresholdOverride(_autoMergeThreshold),
      );
    }
    final savedClustering = localSettings.defaultClusteringDistanceOverride;
    _persistDefaultClusteringDistance = true;
    _defaultClusteringDistance = _clampThreshold(
      savedClustering ?? FaceClusteringService.defaultDistanceThreshold,
      _clusteringMin,
      _clusteringMax,
    );
    FaceClusteringService.defaultDistanceThreshold = _defaultClusteringDistance;
    if (savedClustering != null) {
      unawaited(
        localSettings.setDefaultClusteringDistanceOverride(
          _defaultClusteringDistance,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) =>
      widget.visible ? _buildThresholdsCard(context) : const SizedBox.shrink();

  Widget _buildThresholdsCard(BuildContext context) {
    return SettingsGroupedCard(
      children: [
        _buildThresholdItem(
          context,
          title: "Auto-merge threshold",
          description:
              "Used when creating a new person to auto-merge nearby clusters.",
          value: _autoMergeThreshold,
          defaultValue: PersonService.kDefaultAutoMergeThreshold,
          persistValue: _persistAutoMergeThreshold,
          onPersistChanged: _onAutoMergePersistChanged,
          min: _autoMergeMin,
          max: _autoMergeMax,
          onChanged: _updateAutoMergeThreshold,
        ),
        _buildThresholdItem(
          context,
          title: "Default clustering distance",
          description:
              "Default distance threshold used for clustering new faces.",
          value: _defaultClusteringDistance,
          defaultValue: FaceClusteringService.kRecommendedDistanceThreshold,
          persistValue: _persistDefaultClusteringDistance,
          onPersistChanged: _onClusteringPersistChanged,
          min: _clusteringMin,
          max: _clusteringMax,
          onChanged: _updateDefaultClusteringDistance,
        ),
      ],
    );
  }

  Widget _buildThresholdItem(
    BuildContext context, {
    required String title,
    required String description,
    required double value,
    required double defaultValue,
    required bool persistValue,
    required Future<void> Function(bool) onPersistChanged,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    final textTheme = getEnteTextTheme(context);
    final clampedValue = _clampThreshold(value, min, max);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: textTheme.smallBold),
          const SizedBox(height: 4),
          Text(description, style: textTheme.miniMuted),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(min.toStringAsFixed(2), style: textTheme.mini),
              Expanded(
                child: Slider(
                  value: clampedValue,
                  min: min,
                  max: max,
                  divisions: _divisionsForRange(min, max),
                  onChanged: (value) {
                    onChanged(_roundToStep(value));
                  },
                ),
              ),
              Text(max.toStringAsFixed(2), style: textTheme.mini),
            ],
          ),
          Text(
            "Current: ${clampedValue.toStringAsFixed(2)}",
            style: textTheme.miniMuted,
          ),
          const SizedBox(height: 4),
          Text(
            "Default: ${defaultValue.toStringAsFixed(2)}",
            style: textTheme.miniMuted,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text("Save on device", style: textTheme.mini),
              ToggleSwitchWidget(
                value: () => persistValue,
                onChanged: () => onPersistChanged(!persistValue),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _divisionsForRange(double min, double max) {
    return ((max - min) / _thresholdStep).round();
  }

  double _roundToStep(double value) {
    return (value / _thresholdStep).round() * _thresholdStep;
  }

  double _clampThreshold(double value, double min, double max) {
    return value.clamp(min, max).toDouble();
  }

  void _updateAutoMergeThreshold(double value) {
    final rounded = _roundToStep(value);
    PersonService.autoMergeThreshold = rounded;
    if (_persistAutoMergeThreshold) {
      unawaited(localSettings.setAutoMergeThresholdOverride(rounded));
    }
    setState(() {
      _autoMergeThreshold = rounded;
    });
  }

  Future<void> _onAutoMergePersistChanged(bool value) async {
    setState(() {
      _persistAutoMergeThreshold = value;
    });
    if (value) {
      await localSettings.setAutoMergeThresholdOverride(_autoMergeThreshold);
    }
  }

  void _updateDefaultClusteringDistance(double value) {
    final rounded = _roundToStep(value);
    FaceClusteringService.defaultDistanceThreshold = rounded;
    if (_persistDefaultClusteringDistance) {
      unawaited(localSettings.setDefaultClusteringDistanceOverride(rounded));
    }
    setState(() {
      _defaultClusteringDistance = rounded;
    });
  }

  Future<void> _onClusteringPersistChanged(bool value) async {
    setState(() {
      _persistDefaultClusteringDistance = value;
    });
    if (value) {
      await localSettings.setDefaultClusteringDistanceOverride(
        _defaultClusteringDistance,
      );
    }
  }
}
