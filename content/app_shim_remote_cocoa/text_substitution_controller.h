// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef CONTENT_APP_SHIM_REMOTE_COCOA_TEXT_SUBSTITUTION_CONTROLLER_H_
#define CONTENT_APP_SHIM_REMOTE_COCOA_TEXT_SUBSTITUTION_CONTROLLER_H_

#import <AppKit/AppKit.h>

#include <string>

#include "ui/gfx/range/range.h"

// The text state and services the substitution offer lifecycle needs from
// the view hosting it. RenderWidgetHostViewCocoa implements this.
@protocol TextSubstitutionClient <NSObject>

// The available text window, its document offset, and the selection, as of
// the latest renderer update.
- (const std::u16string&)availableText;
- (size_t)availableTextOffset;
- (gfx::Range)textSelectionRange;

- (NSSpellChecker*)spellChecker;

// The text checking types the focused field permits, and the ones the
// user's settings enable.
- (NSTextCheckingType)allowedTextCheckingTypes;
- (NSTextCheckingType)enabledTextCheckingTypes;

// Whether the hosting profile is off the record; response learning is
// withheld while it is.
- (BOOL)isOffTheRecord;

// Inserts `text` over `replacementRange` (document coordinates), the same
// path typed text takes.
- (void)insertSubstitutionText:(NSString*)text
              replacementRange:(NSRange)replacementRange;

// The renderer-layout rectangle for `range`, delivered asynchronously in
// the view's coordinate system; `success` is false when no layout answer
// exists for the range.
- (void)layoutFirstRectForCharacterRange:(gfx::Range)range
                              completion:
                                  (void (^)(NSRect rectInViewCoordinates,
                                            bool success))completion;

// The approximate rectangle for `range` in view coordinates, answered
// synchronously from the IME caches; the fallback anchor for editors that
// produce no layout answer.
- (NSRect)approximateFirstRectForCharacterRange:(NSRange)range;

// The view the correction indicator is anchored in.
- (NSView*)viewForCorrectionIndicator;

@end

// Owns the macOS text-substitution offer lifecycle for one
// RenderWidgetHostViewCocoa: computing candidates against the available
// text, parking them with staleness guards, pacing and showing the AppKit
// correction indicator, arbitrating acceptance by text state, remembering
// rejected and reverted offers, and recording the user's responses with the
// spell checker. WebKit's analogue is AlternativeTextController.
@interface TextSubstitutionController : NSObject

- (instancetype)initWithClient:(id<TextSubstitutionClient>)client
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// This controller's session identity with the spell checker, allocated on
// first use. The client's other checker sessions (candidate requests) share
// it.
@property(readonly) NSInteger spellDocumentTag;

// Closes the spell document session. Called from the client's dealloc,
// which passes the checker because the weak client reference is already nil
// while the client deallocates.
- (void)closeSpellDocumentWithChecker:(NSSpellChecker*)spellChecker;

// Called for every key event passing through the view. The ledger tells a
// click-caused indicator resolution from a key-caused one.
- (void)noteKeyEvent;

// Called when typing inserts text or a word-bounding editing command
// (Return, Tab): the matching renderer text update owes a substitution
// check.
- (void)noteTypedInsertionOwingCheck;

// Called for every renderer text update, after the client's text state has
// been updated. Runs the owed substitution check, or re-arbitrates the
// parked candidate against the new state.
- (void)textStateDidChange;

// Runs the substitution check against the current text state. Also driven
// directly by tests.
- (void)requestTextSubstitutions;

// Shows the indicator for the held offer, re-validating it first. The pause
// timer's target; also driven directly by tests.
- (void)showPendingSubstitutionIndicatorNow;

// Dismisses a visible indicator, retiring the shown offer first so the
// dismissal is not mistaken for a resolution AppKit performed on its own.
- (void)dismissCorrectionIndicator;

@end

#endif  // CONTENT_APP_SHIM_REMOTE_COCOA_TEXT_SUBSTITUTION_CONTROLLER_H_
