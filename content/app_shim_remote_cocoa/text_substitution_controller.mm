// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "content/app_shim_remote_cocoa/text_substitution_controller.h"

#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/metrics/histogram_functions.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "content/common/features.h"

namespace {

// How long typing must pause before a held substitution offer is shown.
// WebKit's correctionPanelTimerInterval.
constexpr base::TimeDelta kSubstitutionIndicatorPause = base::Milliseconds(300);

// Cap on typed insertions still owing a substitution check, in case their
// text updates never arrive; a stale check is harmless, an unbounded count
// is not.
constexpr NSUInteger kMaxPendingTextSubstitutionChecks = 16;

// How a substitution offer ended, from the user's point of view. These
// values are persisted to logs. Entries should not be renumbered and numeric
// values should never be reused.
// LINT.IfChange(MacTextSubstitutionResponse)
enum class MacTextSubstitutionResponse {
  kAccepted = 0,
  kRejected = 1,
  kIgnored = 2,
  kReverted = 3,
  kAppliedSilently = 4,
  kMaxValue = kAppliedSilently,
};
// LINT.ThenChange(//tools/metrics/histograms/metadata/input/enums.xml:MacTextSubstitutionResponse)

void RecordSubstitutionResponseMetric(MacTextSubstitutionResponse response) {
  base::UmaHistogramEnumeration("InputMethod.MacTextSubstitution.Response",
                                response);
}

}  // namespace

@implementation TextSubstitutionController {
  __weak id<TextSubstitutionClient> _client;

  NSInteger _spellDocumentTag;
  NSTextCheckingResult* __strong _pendingSubstitution;
  NSString* __strong _pendingSubstitutionOriginal;
  NSString* __strong _pendingSubstitutionLanguage;
  BOOL _pendingSubstitutionWasShown;
  NSTextCheckingResult* __strong _shownSubstitution;
  NSString* __strong _shownSubstitutionOriginal;
  NSString* __strong _rejectedSubstitutionOriginal;
  NSString* __strong _rejectedSubstitutionReplacement;
  NSRange _rejectedSubstitutionRange;
  NSString* __strong _appliedSubstitutionOriginal;
  NSString* __strong _appliedSubstitutionReplacement;
  NSString* __strong _appliedSubstitutionLanguage;
  NSRange _appliedSubstitutionRange;
  BOOL _appliedSubstitutionRevertRecorded;
  NSUInteger _keyEventCount;
  NSUInteger _keyEventCountAtIndicatorShow;
  NSUInteger _pendingTextSubstitutionChecks;
  BOOL _substitutionWasApplied;
  base::OneShotTimer _substitutionIndicatorPauseTimer;
}

- (instancetype)initWithClient:(id<TextSubstitutionClient>)client {
  if ((self = [super init])) {
    _client = client;
  }
  return self;
}

- (NSInteger)spellDocumentTag {
  if (!_spellDocumentTag)
    _spellDocumentTag = [NSSpellChecker uniqueSpellDocumentTag];
  return _spellDocumentTag;
}

- (void)closeSpellDocumentWithChecker:(NSSpellChecker*)spellChecker {
  if (_spellDocumentTag)
    [spellChecker closeSpellDocumentWithTag:_spellDocumentTag];
  _spellDocumentTag = 0;
}

- (void)noteKeyEvent {
  _keyEventCount++;
}

- (void)noteTypedInsertionOwingCheck {
  if (_pendingTextSubstitutionChecks < kMaxPendingTextSubstitutionChecks) {
    _pendingTextSubstitutionChecks++;
  }
}

- (void)textStateDidChange {
  BOOL updateFollowsTyping = _pendingTextSubstitutionChecks > 0;
  _substitutionWasApplied = NO;

  // The rejected-offer memory names a word instance; it holds only while
  // that word still sits at its range, and clears when the text there
  // changes or leaves the window. Deleting and retyping the word earns a
  // fresh offer, as it does in Safari, where the rejection marker dies with
  // the text that carries it.
  if (_rejectedSubstitutionOriginal) {
    NSString* availableText = base::SysUTF16ToNSString([_client availableText]);
    size_t offset = [_client availableTextOffset];
    NSRange rangeInAvailableText =
        NSMakeRange(_rejectedSubstitutionRange.location - offset,
                    _rejectedSubstitutionRange.length);
    if (_rejectedSubstitutionRange.location < offset ||
        NSMaxRange(rangeInAvailableText) > availableText.length ||
        ![[availableText substringWithRange:rangeInAvailableText]
            isEqualToString:_rejectedSubstitutionOriginal]) {
      _rejectedSubstitutionOriginal = nil;
      _rejectedSubstitutionReplacement = nil;
      _rejectedSubstitutionRange = NSMakeRange(NSNotFound, 0);
    }
  }

  // Continuing the word rejects a visible offer; a boundary keystroke or a
  // click on the indicator accepts it. Deliberately more conservative than
  // AppKit's own accept-on-any-key resolution.
  [self dismissCorrectionIndicator];

  if (updateFollowsTyping && [_client textSelectionRange].is_empty()) {
    _pendingTextSubstitutionChecks--;
    [self requestTextSubstitutions];
  } else if (!updateFollowsTyping) {
    // Text or selection changed by something other than typing: re-arbitrate
    // the parked candidate against the new text state. A caret that left its
    // word kills the offer.
    [self resolvePendingSubstitution];
  }
}

- (void)requestTextSubstitutions {
  NSTextCheckingType textCheckingTypes =
      [_client allowedTextCheckingTypes] & [_client enabledTextCheckingTypes];
  if (!textCheckingTypes)
    return;

  // The checker generates correction results only when spelling checking is
  // part of the same request. Spelling and orthography results are markers
  // with no replacement string, skipped below.
  NSTextCheckingType requestedTypes = textCheckingTypes;
  if (requestedTypes & NSTextCheckingTypeCorrection) {
    requestedTypes |=
        NSTextCheckingTypeSpelling | NSTextCheckingTypeOrthography;
  }

  NSString* availableText = base::SysUTF16ToNSString([_client availableText]);

  if (!availableText)
    return;

  auto* textCheckingResults =
      [[_client spellChecker] checkString:availableText
                                    range:NSMakeRange(0, availableText.length)
                                    types:requestedTypes
                                  options:nil
                   inSpellDocumentWithTag:self.spellDocumentTag
                              orthography:nullptr
                                wordCount:nullptr];

  // A candidate either covers the word still being typed (the insertion
  // point touches its range) or the word the last keystroke just completed
  // (its range ends one character before the insertion point). The latter
  // is applied on the spot by -resolvePendingSubstitution's boundary
  // guards; the former is parked until its boundary arrives.
  NSUInteger cursorLocation = [_client textSelectionRange].start();
  NSTextCheckingResult* wordBeingTypedCandidate;
  NSTextCheckingResult* justCompletedWordCandidate;
  NSString* dominantLanguage;
  for (NSTextCheckingResult* result in textCheckingResults) {
    NSTextCheckingResult* adjustedResult =
        [result resultByAdjustingRangesWithOffset:[_client availableTextOffset]];
    if (adjustedResult.resultType == NSTextCheckingTypeOrthography) {
      dominantLanguage = adjustedResult.orthography.dominantLanguage;
      continue;
    }
    if (!adjustedResult.replacementString)
      continue;
    BOOL touchesCursor = NSLocationInRange(
        cursorLocation, NSMakeRange(adjustedResult.range.location,
                                    adjustedResult.range.length + 1));
    constexpr NSTextCheckingType textCheckingTypesToReplaceImmediately =
        NSTextCheckingTypeQuote | NSTextCheckingTypeDash;
    if (adjustedResult.resultType & textCheckingTypesToReplaceImmediately) {
      if (touchesCursor) {
        [_client insertSubstitutionText:adjustedResult.replacementString
                       replacementRange:adjustedResult.range];
      }
      continue;
    }
    if (touchesCursor)
      wordBeingTypedCandidate = adjustedResult;
    else if (cursorLocation == NSMaxRange(adjustedResult.range) + 1)
      justCompletedWordCandidate = adjustedResult;
  }

  [self parkSubstitutionCandidate:justCompletedWordCandidate
                           inText:availableText
                         language:dominantLanguage];
  [self resolvePendingSubstitution];
  [self parkSubstitutionCandidate:wordBeingTypedCandidate
                           inText:availableText
                         language:dominantLanguage];
  [self resolvePendingSubstitution];
  if (_pendingSubstitution)
    [self scheduleSubstitutionIndicatorAfterPause];
}

// Parks `candidate` as the pending substitution, with the text it was
// computed for as a staleness guard. A nil candidate leaves the previously
// parked one in place: the boundary that completes a word can arrive in a
// later text update than the last check that could still see the word under
// the insertion point.
- (void)parkSubstitutionCandidate:(NSTextCheckingResult*)candidate
                           inText:(NSString*)availableText
                         language:(NSString*)language {
  if (!candidate)
    return;
  NSRange rangeInAvailableText =
      NSMakeRange(candidate.range.location - [_client availableTextOffset],
                  candidate.range.length);
  NSString* originalString =
      [availableText substringWithRange:rangeInAvailableText];
  // The most recently rejected offer is not made again while the rejected
  // word instance survives; a fresh instance of the same word elsewhere
  // offers normally.
  if ([_rejectedSubstitutionOriginal isEqualToString:originalString] &&
      [_rejectedSubstitutionReplacement
          isEqualToString:candidate.replacementString] &&
      NSEqualRanges(_rejectedSubstitutionRange, candidate.range)) {
    return;
  }
  // Neither is a correction the user manually backed out: the same word in
  // the same place drawing the same correction after an apply means the
  // user restored their word, and re-offering it would fight them. The
  // first re-sighting is the undo itself — record it as Reverted, the
  // response native text views record when a correction is backed out.
  if ([_appliedSubstitutionOriginal isEqualToString:originalString] &&
      [_appliedSubstitutionReplacement
          isEqualToString:candidate.replacementString] &&
      NSIntersectionRange(_appliedSubstitutionRange, candidate.range).length >
          0) {
    if (!_appliedSubstitutionRevertRecorded) {
      _appliedSubstitutionRevertRecorded = YES;
      [self recordSubstitutionResponse:NSCorrectionResponseReverted
                          toCorrection:candidate.replacementString
                               forWord:originalString
                              language:_appliedSubstitutionLanguage ?: language];
    }
    return;
  }
  // A fresh result for the same word and replacement is the same offer; it
  // keeps the shown status so an acceptance still records. A different offer
  // displacing a shown one means the shown one was typed through unaccepted.
  BOOL sameOffer =
      _pendingSubstitution &&
      NSEqualRanges(_pendingSubstitution.range, candidate.range) &&
      [_pendingSubstitution.replacementString
          isEqualToString:candidate.replacementString];
  if (_pendingSubstitutionWasShown && !sameOffer) {
    [self recordSubstitutionResponse:NSCorrectionResponseIgnored
                        toCorrection:_pendingSubstitution.replacementString
                             forWord:_pendingSubstitutionOriginal
                            language:_pendingSubstitutionLanguage];
    _pendingSubstitutionWasShown = NO;
  }
  _pendingSubstitution = candidate;
  _pendingSubstitutionOriginal = originalString;
  _pendingSubstitutionLanguage = language;
}

- (void)scheduleSubstitutionIndicatorAfterPause {
  // Kill switch for the pacing delta: disabled, every parked offer shows
  // immediately, the indicator cadence this change replaces. Acceptance
  // arbitration is unaffected either way.
  if (!base::FeatureList::IsEnabled(
          features::kMacSubstitutionOfferPacing)) {
    [self showPendingSubstitutionIndicatorNow];
    return;
  }
  // Show the indicator only when typing pauses with a candidate still held;
  // at typing speed substitutions apply silently at the word boundary. Each
  // keystroke's check restarts the timer;
  // -showPendingSubstitutionIndicatorNow re-validates the offer when it
  // fires. The timer dies with this controller, so the callback's weak self
  // is never stale, only possibly nil.
  __weak TextSubstitutionController* weakSelf = self;
  _substitutionIndicatorPauseTimer.Start(
      FROM_HERE, kSubstitutionIndicatorPause, base::BindOnce(^{
        [weakSelf showPendingSubstitutionIndicatorNow];
      }));
}

- (void)showPendingSubstitutionIndicatorNow {
  if (!_pendingSubstitution || _shownSubstitution == _pendingSubstitution)
    return;
  // The indicator is an offer about the word being typed; it is only shown
  // while the insertion point still sits at the end of that word.
  gfx::Range textSelectionRange = [_client textSelectionRange];
  if (!textSelectionRange.IsValid() || !textSelectionRange.is_empty() ||
      textSelectionRange.GetMin() != NSMaxRange(_pendingSubstitution.range)) {
    return;
  }
  // Anchor the indicator from the renderer's layout, not from
  // -firstRectForCharacterRange:, whose IME caches may approximate a word
  // range's rect with the caret's. The layout answer arrives asynchronously;
  // the show completes when it does, re-validated against the offer still
  // being current.
  NSTextCheckingResult* result = _pendingSubstitution;
  __weak TextSubstitutionController* weakSelf = self;
  [_client layoutFirstRectForCharacterRange:gfx::Range::FromPossiblyInvalidNSRange(
                                                result.range)
                                 completion:^(NSRect rectInViewCoordinates,
                                              bool success) {
                                   [weakSelf
                                       showSubstitutionIndicatorForResult:result
                                                               layoutRect:
                                                                   rectInViewCoordinates
                                                          layoutRectValid:success];
                                 }];
}

- (void)showSubstitutionIndicatorForResult:(NSTextCheckingResult*)result
                                layoutRect:(NSRect)layoutRectInViewCoordinates
                           layoutRectValid:(bool)success {
  // Typing may have continued while the layout answer was in flight,
  // re-parking or dropping the offer; a reply about a retired offer must
  // not show. The checks mirror the ones made when the query was issued.
  if (result != _pendingSubstitution || _shownSubstitution == result)
    return;
  gfx::Range textSelectionRange = [_client textSelectionRange];
  if (!textSelectionRange.IsValid() || !textSelectionRange.is_empty() ||
      textSelectionRange.GetMin() != NSMaxRange(result.range)) {
    return;
  }

  NSRect textRectInViewCoordinates = layoutRectInViewCoordinates;
  if (!success) {
    // EditContext-style editors report caret and selection bounds but
    // produce no layout rect for an arbitrary range; fall back to the
    // cached path rather than never offering there.
    textRectInViewCoordinates =
        [_client approximateFirstRectForCharacterRange:result.range];
  }

  _pendingSubstitutionWasShown = YES;
  _shownSubstitution = _pendingSubstitution;
  _shownSubstitutionOriginal = _pendingSubstitutionOriginal;
  _keyEventCountAtIndicatorShow = _keyEventCount;

  NSString* originalString = _pendingSubstitutionOriginal;

  __weak TextSubstitutionController* weakSelf = self;
  [[_client spellChecker]
      showCorrectionIndicatorOfType:NSCorrectionIndicatorTypeDefault
                      primaryString:result.replacementString
                 alternativeStrings:result.alternativeStrings
                    forStringInRect:textRectInViewCoordinates
                               view:[_client viewForCorrectionIndicator]
                  completionHandler:^(NSString* acceptedString) {
                    [weakSelf
                        correctionIndicatorResolvedWithString:acceptedString
                                        forTextCheckingResult:result
                                               originalString:originalString];
                  }];
}

- (void)correctionIndicatorResolvedWithString:(NSString*)acceptedString
                        forTextCheckingResult:(NSTextCheckingResult*)correction
                               originalString:(NSString*)originalString {
  // -dismissCorrectionIndicator retires the shown offer before dismissing,
  // so if the offer is still current here, AppKit resolved the indicator on
  // its own.
  BOOL offerWasCurrent = _shownSubstitution == correction;
  if (offerWasCurrent) {
    _shownSubstitution = nil;
    _shownSubstitutionOriginal = nil;
  }

  if (acceptedString) {
    // AppKit resolves the indicator with its string not only on a click but
    // on any key event, ahead of the keystroke's own text update, which may
    // be about to kill the offer. The cause is directly observable: a
    // resolution delivered during the key event's dispatch runs with that
    // event as NSApp.currentEvent, and one deferred past the dispatch runs
    // after the event has passed through this view and advanced
    // _keyEventCount. A click is a resolution with neither sign, and only
    // then is no keystroke in flight, making an immediate apply sound.
    // Key-event resolutions defer to the text arbitration in
    // -resolvePendingSubstitution.
    //
    // This discrimination rests on observed AppKit delivery timing — a
    // synchronous resolution runs inside the causing event's dispatch, a
    // deferred one only after that dispatch has passed through this view.
    // Should a macOS release change that timing, the failure mode is a
    // click misread as a key resolution: a missed accept, never a misapply.
    NSEventType eventType = NSApp.currentEvent.type;
    BOOL resolvedByKeyEvent = eventType == NSEventTypeKeyDown ||
                              eventType == NSEventTypeKeyUp ||
                              eventType == NSEventTypeFlagsChanged ||
                              _keyEventCount != _keyEventCountAtIndicatorShow;
    if (resolvedByKeyEvent &&
        base::FeatureList::IsEnabled(
            features::kMacSubstitutionTextStateArbitration)) {
      return;
    }
    if ([self applySubstitution:correction
                     withString:acceptedString
             ifTextStillMatches:originalString]) {
      [self recordSubstitutionResponse:NSCorrectionResponseAccepted
                          toCorrection:acceptedString
                               forWord:originalString
                              language:_pendingSubstitutionLanguage];
      [self clearPendingSubstitution];
    }
    return;
  }

  if (offerWasCurrent) {
    // AppKit resolved with no replacement on its own: Escape, or the
    // indicator's dismiss control. An explicit rejection kills the offer
    // and is remembered so it is not immediately re-offered.
    _rejectedSubstitutionOriginal = originalString;
    _rejectedSubstitutionReplacement = correction.replacementString;
    _rejectedSubstitutionRange = correction.range;
    [self recordSubstitutionResponse:NSCorrectionResponseRejected
                        toCorrection:correction.replacementString
                             forWord:originalString
                            language:_pendingSubstitutionLanguage];
    [self clearPendingSubstitution];
    return;
  }

  // The tail of a dismissal this controller performed itself; the offer's
  // fate was decided at the dismissal site.
}

// Applies `replacement` over `correction`'s range iff that range still lies
// within the available text window, still reads `originalString`, and no
// substitution has been applied in this text-state cycle. Returns whether it
// applied.
- (BOOL)applySubstitution:(NSTextCheckingResult*)correction
               withString:(NSString*)replacement
       ifTextStillMatches:(NSString*)originalString {
  if (_substitutionWasApplied)
    return NO;
  size_t availableTextOffset = [_client availableTextOffset];
  NSRange availableTextRange =
      NSMakeRange(availableTextOffset, [_client availableText].length());
  if (correction.range.location < availableTextOffset ||
      NSMaxRange(correction.range) > NSMaxRange(availableTextRange)) {
    return NO;
  }
  NSRange rangeInAvailableText = NSMakeRange(
      correction.range.location - availableTextOffset, correction.range.length);
  NSString* currentString = [base::SysUTF16ToNSString([_client availableText])
      substringWithRange:rangeInAvailableText];
  if (![currentString isEqualToString:originalString])
    return NO;
  _substitutionWasApplied = YES;
  // Remembered so that a user who edits the correction back to their word
  // is not corrected again (and the undo is recorded as Reverted); see
  // -parkSubstitutionCandidate:inText:language:.
  _appliedSubstitutionOriginal = [originalString copy];
  _appliedSubstitutionReplacement = [replacement copy];
  _appliedSubstitutionLanguage = [_pendingSubstitutionLanguage copy];
  _appliedSubstitutionRange =
      NSMakeRange(correction.range.location, replacement.length);
  _appliedSubstitutionRevertRecorded = NO;
  [_client insertSubstitutionText:replacement
                 replacementRange:correction.range];
  return YES;
}

- (void)recordSubstitutionResponse:(NSCorrectionResponse)response
                      toCorrection:(NSString*)correction
                           forWord:(NSString*)word
                          language:(NSString*)language {
  switch (response) {
    case NSCorrectionResponseAccepted:
      RecordSubstitutionResponseMetric(MacTextSubstitutionResponse::kAccepted);
      break;
    case NSCorrectionResponseRejected:
      RecordSubstitutionResponseMetric(MacTextSubstitutionResponse::kRejected);
      break;
    case NSCorrectionResponseIgnored:
      RecordSubstitutionResponseMetric(MacTextSubstitutionResponse::kIgnored);
      break;
    case NSCorrectionResponseReverted:
      RecordSubstitutionResponseMetric(MacTextSubstitutionResponse::kReverted);
      break;
    case NSCorrectionResponseNone:
    case NSCorrectionResponseEdited:
      break;
  }
  // Off-the-record typing must not train the per-user correction model, as
  // WebKit ephemeral sessions do with CorrectionPanel. Corrections still
  // apply; only the learning write is withheld. The aggregate count above is
  // not a per-user learning write and is recorded regardless.
  if ([_client isOffTheRecord]) {
    return;
  }
  [[_client spellChecker] recordResponse:response
                            toCorrection:correction
                                 forWord:word
                                language:language
                  inSpellDocumentWithTag:self.spellDocumentTag];
}

- (void)dismissCorrectionIndicator {
  // Retiring the shown offer first lets the completion handler tell this
  // dismissal from one AppKit performed on its own.
  _shownSubstitution = nil;
  _shownSubstitutionOriginal = nil;
  [[_client spellChecker]
      dismissCorrectionIndicatorForView:[_client viewForCorrectionIndicator]];
}

- (void)clearPendingSubstitution {
  _pendingSubstitution = nil;
  _pendingSubstitutionOriginal = nil;
  _pendingSubstitutionLanguage = nil;
  _pendingSubstitutionWasShown = NO;
}

- (void)resolvePendingSubstitution {
  if (!_pendingSubstitution)
    return;

  NSTextCheckingResult* correction = _pendingSubstitution;
  size_t availableTextOffset = [_client availableTextOffset];
  NSRange availableTextRange =
      NSMakeRange(availableTextOffset, [_client availableText].length());

  // If the available text window has moved past the substitution, computing
  // its window-relative position below would underflow.
  if (correction.range.location < availableTextOffset ||
      NSMaxRange(correction.range) > NSMaxRange(availableTextRange)) {
    [self dropPendingSubstitutionUnaccepted];
    return;
  }

  NSAttributedString* attString = [[NSAttributedString alloc]
      initWithString:base::SysUTF16ToNSString([_client availableText])];
  NSRange rangeInAvailableText = NSMakeRange(
      correction.range.location - availableTextOffset, correction.range.length);

  // The word the candidate was computed for has to still be there.
  if (![[attString.string substringWithRange:rangeInAvailableText]
          isEqualToString:_pendingSubstitutionOriginal]) {
    [self dropPendingSubstitutionUnaccepted];
    return;
  }

  // What accepts a substitution is the user's own keystroke landing a word
  // boundary directly behind the word, not whatever text happens to follow
  // it, which proves nothing when typing in front of existing content.
  gfx::Range textSelectionRange = [_client textSelectionRange];
  if (!textSelectionRange.IsValid() || !textSelectionRange.is_empty()) {
    [self dropPendingSubstitutionUnaccepted];
    return;
  }
  NSUInteger caretLocation = textSelectionRange.GetMin();
  if (caretLocation == NSMaxRange(correction.range)) {
    // The user may still be mid-word; hold the candidate for the next
    // update.
    return;
  }
  if (caretLocation != NSMaxRange(correction.range) + 1) {
    // The insertion point is anywhere else: the offer's context is gone.
    [self dropPendingSubstitutionUnaccepted];
    return;
  }

  NSRange trailingRange = NSMakeRange(
      NSMaxRange(correction.range),
      NSMaxRange(availableTextRange) - NSMaxRange(correction.range));
  NSRange trailingRangeInAvailableText = NSMakeRange(
      trailingRange.location - availableTextOffset, trailingRange.length);
  NSString* trailingString =
      [attString.string substringWithRange:trailingRangeInAvailableText];
  if ([[_client spellChecker]
          preventsAutocorrectionBeforeString:trailingString
                                    language:nil]) {
    [self dropPendingSubstitutionUnaccepted];
    return;
  }

  if ([attString doubleClickAtIndex:trailingRangeInAvailableText.location]
          .location < trailingRangeInAvailableText.location) {
    // The character behind the word continues it rather than bounding it:
    // the user typed through the offer.
    [self dropPendingSubstitutionUnaccepted];
    return;
  }

  // Kill switch: with text-state arbitration disabled, a held offer applies
  // only through the indicator's resolution, never silently at a boundary —
  // the accept model this arbitration replaced. The candidate stays parked
  // for the indicator.
  if (!base::FeatureList::IsEnabled(
          features::kMacSubstitutionTextStateArbitration)) {
    return;
  }

  // An offer the user saw and then completed with a boundary is an
  // acceptance; at typing speed nothing was shown and nothing is recorded
  // with the checker.
  BOOL wasShown = _pendingSubstitutionWasShown;
  if ([self applySubstitution:correction
                   withString:correction.replacementString
           ifTextStillMatches:_pendingSubstitutionOriginal]) {
    if (wasShown) {
      [self recordSubstitutionResponse:NSCorrectionResponseAccepted
                          toCorrection:correction.replacementString
                               forWord:_pendingSubstitutionOriginal
                              language:_pendingSubstitutionLanguage];
    } else {
      RecordSubstitutionResponseMetric(
          MacTextSubstitutionResponse::kAppliedSilently);
    }
  }
  [self clearPendingSubstitution];
}

// Clears the pending substitution without applying it; an offer the user
// had seen is reported to the checker as ignored.
- (void)dropPendingSubstitutionUnaccepted {
  if (_pendingSubstitutionWasShown) {
    [self recordSubstitutionResponse:NSCorrectionResponseIgnored
                        toCorrection:_pendingSubstitution.replacementString
                             forWord:_pendingSubstitutionOriginal
                            language:_pendingSubstitutionLanguage];
  }
  [self clearPendingSubstitution];
}

@end
