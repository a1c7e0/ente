import "dart:async";

import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/people_changed_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/ml/body.dart";
import "package:photos/models/ml/face/person.dart";
import "package:photos/services/machine_learning/face_ml/feedback/cluster_feedback.dart";
import "package:photos/services/machine_learning/face_ml/person/person_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/viewer/people/cluster_page.dart";
import "package:photos/ui/viewer/people/face_thumbnail_squircle.dart";
import "package:photos/ui/viewer/people/merge_clusters_to_person_sheet.dart";
import "package:photos/ui/viewer/people/person_face_widget.dart";
import "package:photos/ui/viewer/people/review_thumbnail.dart";
import "package:photos/ui/viewer/people/review_thumbnail_loader.dart";
import "package:photos/ui/viewer/people/save_or_edit_person.dart";
import "package:photos/utils/dialog_util.dart";

final _logger = Logger("PersonGallerySuggestion");

class PersonGallerySuggestion extends StatefulWidget {
  final PersonEntity? person;
  final VoidCallback? onClose;

  const PersonGallerySuggestion({
    required this.person,
    this.onClose,
    super.key,
  });

  @override
  State<PersonGallerySuggestion> createState() =>
      _PersonGallerySuggestionState();
}

class _PersonGallerySuggestionState extends State<PersonGallerySuggestion>
    with TickerProviderStateMixin {
  List<ClusterSuggestion> allSuggestions = [];
  int currentSuggestionIndex = 0;
  ReviewThumbnails faceCrops = {};
  bool isLoading = true;
  bool isProcessing = false;
  bool isPreparingNext = false;
  bool hasCurrentSuggestion = false;
  late ReviewThumbnailLoader _thumbnailLoader;
  Object? _thumbnailError;
  late final StreamSubscription<PeopleChangedEvent> _peopleChangedEvent;
  int _suggestionLoadID = 0;

  PersonEntity? person;
  bool get personPage => widget.person != null;
  PersonEntity get relevantPerson => widget.person ?? person!;

  AnimationController? _slideController;
  AnimationController? _fadeController;
  Animation<Offset>? _slideAnimation;
  Animation<double>? _fadeAnimation;

  @override
  void initState() {
    super.initState();
    person = widget.person;
    _thumbnailLoader = ReviewThumbnailLoader(personPage ? 4 : 3);
    _initializeAnimations();
    _peopleChangedEvent = Bus.instance.on<PeopleChangedEvent>().listen((event) {
      if (personPage &&
          event.type == PeopleEventType.reviewedSuggestion &&
          event.person?.remoteID == widget.person!.remoteID) {
        unawaited(_reloadSuggestions());
      }
    });
    _loadInitialSuggestion();
  }

  void _initializeAnimations() {
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -1.0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _slideController!,
            curve: Curves.easeOutCubic,
          ),
        );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController!, curve: Curves.easeInOut),
    );
  }

  Future<void> _loadInitialSuggestion() async {
    final loadID = ++_suggestionLoadID;
    try {
      late final List<ClusterSuggestion> suggestions;
      if (personPage) {
        suggestions = await ClusterFeedbackService.instance
            .getSuggestionForPerson(relevantPerson);
      } else {
        suggestions = await ClusterFeedbackService.instance
            .getAllLargePersonSuggestions();
        if (suggestions.isNotEmpty) {
          person = suggestions.first.person;
        }
      }

      if (suggestions.isNotEmpty && mounted && loadID == _suggestionLoadID) {
        allSuggestions = suggestions;
        currentSuggestionIndex = 0;

        if (!await _prepareSuggestionAt(0, loadID)) return;

        if (mounted && loadID == _suggestionLoadID) {
          setState(() {
            isLoading = false;
            hasCurrentSuggestion = true;
          });
        }

        if (mounted &&
            loadID == _suggestionLoadID &&
            _fadeController != null &&
            _slideController != null) {
          unawaited(_fadeController?.forward());
          unawaited(_slideController?.forward());
        }
      } else {
        _logger.info("No suggestions found");
        if (mounted && loadID == _suggestionLoadID) {
          _thumbnailLoader.prefetch(const []);
          setState(() {
            allSuggestions = [];
            currentSuggestionIndex = 0;
            faceCrops = {};
            isLoading = false;
            isProcessing = false;
            isPreparingNext = false;
            hasCurrentSuggestion = false;
          });
        }
      }
    } catch (e, s) {
      _logger.severe("Error loading suggestion", e, s);
      if (mounted && loadID == _suggestionLoadID) {
        setState(() {
          isLoading = false;
          _thumbnailError = e;
        });
      }
    }
  }

  Future<void> _reloadSuggestions() async {
    _thumbnailLoader.dispose();
    _thumbnailLoader = ReviewThumbnailLoader(personPage ? 4 : 3);
    _thumbnailError = null;
    _slideController?.reset();
    _fadeController?.reset();
    if (mounted) {
      setState(() {
        isLoading = true;
        isProcessing = false;
        isPreparingNext = false;
        hasCurrentSuggestion = false;
        allSuggestions = [];
        currentSuggestionIndex = 0;
        faceCrops = {};
      });
    }
    await _loadInitialSuggestion();
  }

  Future<bool> _prepareSuggestionAt(int index, int loadID) async {
    final prepared = await _thumbnailLoader.next(allSuggestions.skip(index));
    if (!mounted || loadID != _suggestionLoadID || prepared == null) {
      return false;
    }
    final selectedIndex = allSuggestions.indexOf(prepared.suggestion, index);
    final selected = allSuggestions.removeAt(selectedIndex);
    allSuggestions.insert(index, selected);
    faceCrops = prepared.thumbnails;
    person = selected.person;
    _thumbnailError = null;
    _thumbnailLoader.prefetch(allSuggestions.skip(index + 1));
    return true;
  }

  Future<void> _retryThumbnails() async {
    final loadID = _suggestionLoadID;
    _thumbnailLoader.retryFailures();
    setState(() {
      _thumbnailError = null;
      isLoading = true;
    });
    if (allSuggestions.isEmpty) {
      await _loadInitialSuggestion();
      return;
    }
    await _prepareNextSuggestion(advance: false);
    if (mounted && loadID == _suggestionLoadID) {
      setState(() => isLoading = false);
    }
  }

  Future<void> _navigateToCluster() async {
    if (allSuggestions.isEmpty ||
        currentSuggestionIndex >= allSuggestions.length) {
      return;
    }

    final currentSuggestion = allSuggestions[currentSuggestionIndex];
    final List<EnteFile> sortedFiles = List<EnteFile>.from(
      currentSuggestion.filesInCluster,
    );
    sortedFiles.sort((a, b) => b.creationTime!.compareTo(a.creationTime!));
    final result = await Navigator.of(context).push<ClusterPageResult>(
      MaterialPageRoute(
        builder: (context) => ClusterPage(
          sortedFiles,
          personID: relevantPerson,
          clusterID: currentSuggestion.clusterIDToMerge,
          showNamingBanner: false,
        ),
      ),
    );

    if (!mounted || result != ClusterPageResult.ignoredPerson) {
      return;
    }

    await _consumeCurrentSuggestionAfterExternalAction();
  }

  Future<void> _consumeCurrentSuggestionAfterExternalAction() async {
    if (isProcessing ||
        allSuggestions.isEmpty ||
        currentSuggestionIndex >= allSuggestions.length) {
      return;
    }

    final loadID = _suggestionLoadID;
    setState(() {
      isProcessing = true;
    });

    try {
      await _animateOut();
      if (!mounted || loadID != _suggestionLoadID) {
        return;
      }
      setState(() {
        hasCurrentSuggestion = false;
      });
      await _prepareNextSuggestion();
    } catch (e, s) {
      _logger.severe("Error consuming suggestion after external action", e, s);
      if (mounted && loadID == _suggestionLoadID) {
        setState(() {
          isProcessing = false;
        });
      }
    }
  }

  Future<void> _handleUserChoice(bool accepted) async {
    if (isProcessing ||
        allSuggestions.isEmpty ||
        currentSuggestionIndex >= allSuggestions.length) {
      return;
    }

    final loadID = _suggestionLoadID;
    setState(() {
      isProcessing = true;
    });

    try {
      final currentSuggestion = allSuggestions[currentSuggestionIndex];
      final feedbackFuture = accepted
          ? ClusterFeedbackService.instance.addClusterToExistingPerson(
              person: relevantPerson,
              clusterID: currentSuggestion.clusterIDToMerge,
            )
          : _captureNotPersonFeedback(currentSuggestion);

      await Future.wait([
        _animateOut().then((_) {
          if (mounted && loadID == _suggestionLoadID) {
            setState(() => hasCurrentSuggestion = false);
          }
        }),
        feedbackFuture,
      ]);
      if (!mounted || loadID != _suggestionLoadID) return;
      if (mounted) {
        setState(() {
          hasCurrentSuggestion = false;
        });
      }
      await _prepareNextSuggestion();
    } catch (e, s) {
      _logger.severe("Error handling user choice", e, s);
      if (mounted && loadID == _suggestionLoadID) {
        setState(() {
          isProcessing = false;
          hasCurrentSuggestion = true;
        });
        await _animateIn();
        if (mounted) await showGenericErrorDialog(context: context, error: e);
      }
    }
  }

  Future<void> _captureNotPersonFeedback(ClusterSuggestion suggestion) async {
    await ClusterFeedbackService.instance.rejectSuggestion(
      personID: suggestion.person.remoteID,
      clusterID: suggestion.clusterIDToMerge,
    );
    Bus.instance.fire(
      PeopleChangedEvent(
        person: suggestion.person,
        source: suggestion.clusterIDToMerge,
      ),
    );
  }

  Future<void> _saveAsAnotherPerson() async {
    if (isProcessing ||
        allSuggestions.isEmpty ||
        currentSuggestionIndex >= allSuggestions.length) {
      return;
    }
    final loadID = _suggestionLoadID;
    setState(() {
      isProcessing = true;
    });
    unawaited(_animateOut());
    try {
      final currentSuggestion = allSuggestions[currentSuggestionIndex];
      person = currentSuggestion.person;
      final clusterID = currentSuggestion.clusterIDToMerge;
      final someFile = currentSuggestion.filesInCluster.first;

      final result = isBodyReference(clusterID)
          ? await showMergeClustersToPersonPage(context)
          : await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => SaveOrEditPerson(
                  clusterID,
                  file: someFile,
                  isEditing: false,
                ),
              ),
            );
      if (result is MergePersonSelectionResult) {
        final selected =
            result.person ??
            await PersonService.instance.getPerson(result.personId);
        if (selected == null) return;
        if (selected.remoteID != currentSuggestion.person.remoteID) {
          await ClusterFeedbackService.instance.rejectSuggestion(
            personID: currentSuggestion.person.remoteID,
            clusterID: clusterID,
          );
        }
        await ClusterFeedbackService.instance.addClusterToExistingPerson(
          person: selected,
          clusterID: clusterID,
        );
      }
      if (!mounted || loadID != _suggestionLoadID) return;
      if (result == null || result == false) {
        unawaited(_animateIn());
        if (mounted) {
          setState(() {
            isProcessing = false;
          });
        }
        return;
      }
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted || loadID != _suggestionLoadID) return;
      if (mounted) {
        setState(() {
          hasCurrentSuggestion = false;
        });
      }

      await _prepareNextSuggestion();
    } catch (e, s) {
      _logger.severe("Error handling user choice", e, s);
      if (mounted && loadID == _suggestionLoadID) {
        setState(() {
          isProcessing = false;
          hasCurrentSuggestion = true;
        });
        await _animateIn();
        if (mounted) await showGenericErrorDialog(context: context, error: e);
      }
    }
  }

  Future<void> _prepareNextSuggestion({bool advance = true}) async {
    if (!mounted) return;

    if (advance) currentSuggestionIndex++;

    if (currentSuggestionIndex < allSuggestions.length) {
      final loadID = _suggestionLoadID;
      try {
        if (!await _prepareSuggestionAt(currentSuggestionIndex, loadID)) return;
        if (mounted) {
          setState(() {
            isProcessing = false;
            isPreparingNext = false;
            hasCurrentSuggestion = true;
          });
          await _animateIn();
        }
      } catch (e, s) {
        _logger.severe("Error preparing next suggestion", e, s);
        if (!mounted || loadID != _suggestionLoadID) return;
        _thumbnailError = e;
        if (mounted) {
          setState(() {
            isProcessing = false;
            isPreparingNext = false;
            hasCurrentSuggestion = false;
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          isProcessing = false;
          isPreparingNext = false;
          hasCurrentSuggestion = false;
        });
      }
    }
  }

  Future<void> _animateOut() async {
    if (mounted && _fadeController != null && _slideController != null) {
      await Future.wait([
        _fadeController!.reverse(),
        _slideController!.reverse(),
      ]);
    }
  }

  Future<void> _animateIn() async {
    if (mounted && _fadeController != null && _slideController != null) {
      _slideController?.reset();
      _fadeController?.reset();
      await Future.wait([
        _fadeController!.forward(),
        _slideController!.forward(),
      ]);
    }
  }

  @override
  void dispose() {
    _suggestionLoadID++;
    _thumbnailLoader.dispose();
    _peopleChangedEvent.cancel();
    _slideController?.dispose();
    _fadeController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_thumbnailError != null) {
      return Center(
        child: TextButton.icon(
          onPressed: _retryThumbnails,
          icon: const Icon(Icons.refresh),
          label: Text(context.strings.retry),
        ),
      );
    }
    if (isLoading || (!hasCurrentSuggestion && isProcessing)) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (isLoading ||
        allSuggestions.isEmpty ||
        currentSuggestionIndex >= allSuggestions.length ||
        !hasCurrentSuggestion ||
        _slideAnimation == null ||
        _fadeAnimation == null) {
      return const SizedBox.shrink();
    }

    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    const primaryActionColor = Color(0xFF08C225);
    final cardRadius = BorderRadius.circular(20);
    final actionButtonRadius = BorderRadius.circular(14);
    const closeButtonSize = 24.0;

    return SlideTransition(
      position: _slideAnimation!,
      child: FadeTransition(
        opacity: _fadeAnimation!,
        child: GestureDetector(
          key: ValueKey('suggestion_$currentSuggestionIndex'),
          onTap: _navigateToCluster,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: colorScheme.backgroundElevated2,
                  borderRadius: cardRadius,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    personPage
                        ? RichText(
                            textAlign: TextAlign.center,
                            text: TextSpan(
                              style: textTheme.body,
                              children: [
                                TextSpan(text: context.strings.areThey),
                                TextSpan(
                                  text: relevantPerson.data.name,
                                  style: textTheme.bodyBold,
                                ),
                                TextSpan(text: context.strings.questionmark),
                              ],
                            ),
                          )
                        : Text(
                            context.strings.sameperson,
                            style: textTheme.body,
                            textAlign: TextAlign.center,
                          ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _buildFaceThumbnails(),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: isProcessing
                                ? null
                                : () => _handleUserChoice(false),
                            child: Container(
                              margin: const EdgeInsets.only(left: 16, right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.fillFaint,
                                borderRadius: actionButtonRadius,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.close,
                                    color: colorScheme.textBase,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    context.strings.no,
                                    style:
                                        (personPage
                                                ? textTheme.bodyBold
                                                : textTheme.body)
                                            .copyWith(
                                              color: colorScheme.textBase,
                                            ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: isProcessing
                                ? null
                                : () => _handleUserChoice(true),
                            child: Container(
                              margin: const EdgeInsets.only(left: 6, right: 16),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: primaryActionColor,
                                borderRadius: actionButtonRadius,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    context.strings.yes,
                                    style:
                                        (personPage
                                                ? textTheme.bodyBold
                                                : textTheme.body)
                                            .copyWith(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (personPage) const SizedBox(height: 12),
                    if (personPage)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: isProcessing
                            ? null
                            : () => _saveAsAnotherPerson(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 32,
                          ),
                          child: Text(
                            context.strings.saveAsAnotherPerson,
                            style: textTheme.mini.copyWith(
                              color: colorScheme.textMuted,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.onClose != null)
                Positioned(
                  top: 16,
                  right: 24,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    child: Container(
                      width: closeButtonSize,
                      height: closeButtonSize,
                      decoration: BoxDecoration(
                        color: colorScheme.fillFaint,
                        borderRadius: BorderRadius.circular(
                          closeButtonSize / 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFaceThumbnails() {
    final currentSuggestion = allSuggestions[currentSuggestionIndex];
    final suggestPerson = currentSuggestion.person;
    final files = currentSuggestion.filesInCluster
        .take(personPage ? 4 : 3)
        .toList();
    final thumbnails = <Widget>[];
    final textTheme = getEnteTextTheme(context);

    final start = personPage ? 0 : -1;
    for (int i = start; i < files.length; i++) {
      EnteFile? file;
      ReviewThumbnail? faceCrop;
      if (i != -1) {
        file = files[i];
        faceCrop = faceCrops[file.uploadedFileID!];
      }

      if (i > start) {
        thumbnails.add(const SizedBox(width: 8));
      }

      thumbnails.add(
        Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: ShapeDecoration(
                shape: faceThumbnailSquircleBorder(side: 72),
                color: getEnteColorScheme(context).fillFaint,
              ),
              child: FaceThumbnailSquircleClip(
                child: (i == -1)
                    ? PersonFaceWidget(
                        personId: suggestPerson.remoteID,
                        key: ValueKey('person_${suggestPerson.remoteID}'),
                      )
                    : ReviewThumbnailWidget(
                        faceCrop!,
                        key: ValueKey((
                          currentSuggestion.person.remoteID,
                          currentSuggestion.clusterIDToMerge,
                          file!.uploadedFileID,
                        )),
                      ),
              ),
            ),
            if (i == -1) const SizedBox(height: 8),
            if (i == -1)
              SizedBox(
                width: 72,
                child: Center(
                  child: Text(
                    relevantPerson.data.name.trim(),
                    style: textTheme.bodyMuted,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return thumbnails;
  }
}
