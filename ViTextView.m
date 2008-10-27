#import "ViTextView.h"
#import "ViLanguageStore.h"
#import "ViThemeStore.h"
#import "ViDocument.h"  // for declaration of the message: method
#import "NSString-scopeSelector.h"
#import "ExCommand.h"
#import "ViAppController.h"  // for sharedBuffers

int logIndent = 0;

@interface ViTextView (private)
- (BOOL)move_right:(ViCommand *)command;
- (void)disableWrapping;
- (BOOL)insert:(ViCommand *)command;
- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation toLocation:(NSUInteger)toLocation;
- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation;
- (void)recordInsertInRange:(NSRange)aRange;
- (void)recordDeleteOfString:(NSString *)aString atLocation:(NSUInteger)aLocation;
- (NSString *)leadingWhitespaceForLineAtLocation:(NSUInteger)aLocation;
- (NSString *)lineForLocation:(NSUInteger)aLocation;
@end

@implementation ViTextView

- (void)initEditorWithDelegate:(id)aDelegate
{
	[self setDelegate:aDelegate];
	[self setCaret:0];
	[[self textStorage] setDelegate:self];

	undoManager = [[self delegate] undoManager];
	parser = [[ViCommand alloc] init];
	buffers = [[NSApp delegate] sharedBuffers];
	storage = [self textStorage];

	wordSet = [NSCharacterSet characterSetWithCharactersInString:@"_"];
	[wordSet formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
	whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

	inputCommands = [NSDictionary dictionaryWithObjectsAndKeys:
			 @"input_newline:", [NSNumber numberWithUnsignedInteger:0x00000024], // enter
			 @"input_newline:", [NSNumber numberWithUnsignedInteger:0x0004002e], // ctrl-m
			 @"input_newline:", [NSNumber numberWithUnsignedInteger:0x00040026], // ctrl-j
			 @"increase_indent:", [NSNumber numberWithUnsignedInteger:0x00040011], // ctrl-t
			 @"decrease_indent:", [NSNumber numberWithUnsignedInteger:0x00040002], // ctrl-d
			 @"input_backspace:", [NSNumber numberWithUnsignedInteger:0x00000033], // backspace
			 @"input_backspace:", [NSNumber numberWithUnsignedInteger:0x00040004], // ctrl-h
			 @"input_forward_delete:", [NSNumber numberWithUnsignedInteger:0x00800075], // delete
			 @"input_tab:", [NSNumber numberWithUnsignedInteger:0x00000030], // tab
			 nil];
	
	normalCommands = [NSDictionary dictionaryWithObjectsAndKeys:
			  /*
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100012], // command-1
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100013], // command-2
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100014], // command-3
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100015], // command-4
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100017], // command-5
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100016], // command-6
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x0010001A], // command-7
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x0010001C], // command-8
			  @"switch_tab:", [NSNumber numberWithUnsignedInteger:0x00100019], // command-9
			  */
			  @"show_scope:", [NSNumber numberWithUnsignedInteger: 0x00060023], // ctrl-shift-p
			 nil];
	
	nonWordSet = [[NSMutableCharacterSet alloc] init];
	[nonWordSet formUnionWithCharacterSet:wordSet];
	[nonWordSet formUnionWithCharacterSet:whitespace];
	[nonWordSet invert];

	[self setRichText:NO];
	[self setImportsGraphics:NO];
	[self setUsesFontPanel:NO];
	[self setUsesFindPanel:NO];
	//[self setPageGuideValues];
	[self disableWrapping];
	[self setContinuousSpellCheckingEnabled:NO];

	[self setTheme:[[ViThemeStore defaultStore] defaultTheme]];
}

- (void)setLanguage:(NSString *)aLanguage
{
	ViLanguage *newLanguage = nil;
	bundle = [[ViLanguageStore defaultStore] bundleForLanguage:aLanguage language:&newLanguage];
	[newLanguage patterns];
	if (newLanguage != language)
	{
		language = newLanguage;
		[self highlightEverything];
	}
}

- (ViLanguage *)language
{
	return language;
}

- (void)configureForURL:(NSURL *)aURL
{
	ViLanguage *newLanguage = nil;
	if (aURL)
	{
		NSString *firstLine = nil;
		NSUInteger eol;
		[self getLineStart:NULL end:NULL contentsEnd:&eol forLocation:0];
		if (eol > 0)
			firstLine = [[storage string] substringWithRange:NSMakeRange(0, eol)];

		bundle = nil;
		if ([firstLine length] > 0)
			bundle = [[ViLanguageStore defaultStore] bundleForFirstLine:firstLine language:&newLanguage];
		if (bundle == nil)
			bundle = [[ViLanguageStore defaultStore] bundleForFilename:[aURL path] language:&newLanguage];
	}

	if (bundle == nil)
	{
		bundle = [[ViLanguageStore defaultStore] defaultBundleLanguage:&newLanguage];
	}

	[newLanguage patterns];
	if (newLanguage != language)
	{
		language = newLanguage;
		[self highlightEverything];
	}
}

#pragma mark -
#pragma mark Vi error messages

- (BOOL)illegal:(ViCommand *)command
{
	[[self delegate] message:@"%C isn't a vi command", command.key];
	return NO;
}

- (BOOL)nonmotion:(ViCommand *)command
{
	[[self delegate] message:@"%C may not be used as a motion command", command.motion_key];
	return NO;
}

- (BOOL)nodot:(ViCommand *)command
{
	[[self delegate] message:@"No command to repeat"];
	return NO;
}

- (BOOL)no_previous_ftFT:(ViCommand *)command
{
	[[self delegate] message:@"No previous F, f, T or t search"];
	return NO;
}

#pragma mark -
#pragma mark Convenience methods

- (void)getLineStart:(NSUInteger *)bol_ptr end:(NSUInteger *)end_ptr contentsEnd:(NSUInteger *)eol_ptr forLocation:(NSUInteger)aLocation
{
	[[storage string] getLineStart:bol_ptr end:end_ptr contentsEnd:eol_ptr forRange:NSMakeRange(aLocation, 0)];
}

- (void)getLineStart:(NSUInteger *)bol_ptr end:(NSUInteger *)end_ptr contentsEnd:(NSUInteger *)eol_ptr
{
	[self getLineStart:bol_ptr end:end_ptr contentsEnd:eol_ptr forLocation:start_location];
}

/* Like insertText:, but works within beginEditing/endEditing
 */
- (void)insertString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	[[storage mutableString] insertString:aString atIndex:aLocation];
}

- (NSString *)lineForLocation:(NSUInteger)aLocation
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol forLocation:aLocation];
	return [[storage string] substringWithRange:NSMakeRange(bol, eol - bol)];
}

- (BOOL)isBlankLineAtLocation:(NSUInteger)aLocation
{
	NSString *line = [self lineForLocation:aLocation];
	return [line rangeOfCharacterFromSet:[[NSCharacterSet whitespaceCharacterSet] invertedSet]].location == NSNotFound;
}

- (NSArray *)scopesAtLocation:(NSUInteger)aLocation
{
	return [[self layoutManager] temporaryAttribute:ViScopeAttributeName
				       atCharacterIndex:aLocation
				         effectiveRange:NULL];
}

#pragma mark -
#pragma mark Indentation

- (NSString *)indentStringOfLength:(int)length
{
	length = IMAX(length, 0);
	int tabstop = [[NSUserDefaults standardUserDefaults] integerForKey:@"tabstop"];
	if ([[NSUserDefaults standardUserDefaults] integerForKey:@"expandtab"] == NSOnState)
	{
		// length * " "
		return [@"" stringByPaddingToLength:length withString:@" " startingAtIndex:0];
	}
	else
	{
		// length / tabstop * "tab" + length % tabstop * " "
		int ntabs = (length / tabstop);
		int nspaces = (length % tabstop);
		NSString *indent = [@"" stringByPaddingToLength:ntabs withString:@"\t" startingAtIndex:0];
		return [indent stringByPaddingToLength:ntabs + nspaces withString:@" " startingAtIndex:0];
	}
}

- (NSString *)indentStringForLevel:(int)level
{
	int shiftWidth = [[NSUserDefaults standardUserDefaults] integerForKey:@"shiftwidth"] * level;
	return [self indentStringOfLength:shiftWidth * level];
}

- (NSString *)leadingWhitespaceForLineAtLocation:(NSUInteger)aLocation
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol forLocation:aLocation];
	NSRange lineRange = NSMakeRange(bol, eol - bol);

	NSRange r = [[storage string] rangeOfCharacterFromSet:[[NSCharacterSet whitespaceCharacterSet] invertedSet]
						      options:0
							range:lineRange];
	// NSLog(@"leadingWhitespaceForLineAtLocation(%u): r = %u + %u", aLocation, r.location, r.length);
	if (r.location != NSNotFound)
	{
		return [[storage string] substringWithRange:NSMakeRange(lineRange.location, r.location - lineRange.location)];
	}

	return nil;
}

- (int)lengthOfIndentString:(NSString *)indent
{
	int tabStop = [[NSUserDefaults standardUserDefaults] integerForKey:@"tabstop"];
	int i;
	int length = 0;
	for (i = 0; i < [indent length]; i++)
	{
		unichar c = [indent characterAtIndex:i];
		if (c == ' ')
			++length;
		else if (c == '\t')
			length += tabStop;
	}

	return length;
}

- (int)lenghtOfIndentAtLine:(NSUInteger)lineLocation
{
	return [self lengthOfIndentString:[self leadingWhitespaceForLineAtLocation:lineLocation]];
}

- (NSString *)bestMatchingScope:(NSArray *)scopeSelectors atLocation:(NSUInteger)aLocation
{
	NSArray *scopes = [self scopesAtLocation:aLocation];
	NSString *foundScopeSelector = nil;
	NSString *scopeSelector;
	u_int64_t highest_rank = 0;
	for (scopeSelector in scopeSelectors)
	{
		u_int64_t rank = [scopeSelector matchesScopes:scopes];
		if (rank > highest_rank)
		{
			foundScopeSelector = scopeSelector;
			highest_rank = rank;
		}
	}
	
	return foundScopeSelector;
}

- (BOOL)shouldIncreaseIndentAtLocation:(NSUInteger)aLocation
{
	NSDictionary *increaseIndentPatterns = [[ViLanguageStore defaultStore] preferenceItems:@"increaseIndentPattern"];
	NSString *bestMatchingScope = [self bestMatchingScope:[increaseIndentPatterns allKeys] atLocation:aLocation];

	if (bestMatchingScope)
	{
		NSString *pattern = [increaseIndentPatterns objectForKey:bestMatchingScope];
		NSString *checkLine = [self lineForLocation:aLocation];

		if ([checkLine rangeOfRegularExpressionString:pattern].location != NSNotFound)
		{
			return YES;
		}
	}
	
	return NO;
}

- (int)insertNewlineAtLocation:(NSUInteger)aLocation indentForward:(BOOL)indentForward
{
        NSString *leading_whitespace = [self leadingWhitespaceForLineAtLocation:aLocation];
		
	[self insertString:@"\n" atLocation:aLocation];
	insert_end_location++;

        if ([[self layoutManager] temporaryAttribute:ViSmartPairAttributeName
                                    atCharacterIndex:aLocation + 1
                                      effectiveRange:NULL] && aLocation > 0)
        {
		// assume indentForward?
		NSString *indent = [self leadingWhitespaceForLineAtLocation:aLocation - 1];
                [self insertString:[NSString stringWithFormat:@"\n%@", indent] atLocation:aLocation + 1];
                insert_end_location += [indent length] + 1;
        }

	if (aLocation != 0 && [[NSUserDefaults standardUserDefaults] integerForKey:@"autoindent"] == NSOnState)
	{
		NSUInteger checkLocation = aLocation;
		if (indentForward)
			checkLocation = aLocation - 1;

		if ([self shouldIncreaseIndentAtLocation:checkLocation])
		{
			int shiftWidth = [[NSUserDefaults standardUserDefaults] integerForKey:@"shiftwidth"];
			leading_whitespace = [self indentStringOfLength:[self lengthOfIndentString:leading_whitespace] + shiftWidth];
		}

		if (leading_whitespace)
		{
			[self insertString:leading_whitespace atLocation:aLocation + (indentForward ? 1 : 0)];
			insert_end_location += [leading_whitespace length];
			return 1 + [leading_whitespace length];
		}
	}

	return 1;
}

- (int)changeIndentation:(int)delta inRange:(NSRange)aRange
{
	[undoManager beginUndoGrouping];

	int shiftWidth = [[NSUserDefaults standardUserDefaults] integerForKey:@"shiftwidth"];
	NSUInteger bol;
	[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:aRange.location];

	int delta_offset;
	BOOL has_delta_offset = NO;
	
	while (bol < NSMaxRange(aRange))
	{
		NSString *indent = [self leadingWhitespaceForLineAtLocation:bol];
		int n = [self lengthOfIndentString:indent];
		NSString *newIndent = [self indentStringOfLength:n + delta * shiftWidth];
	
		NSRange indentRange = NSMakeRange(bol, [indent length]);
		[self recordReplacementOfRange:indentRange withLength:[newIndent length]];
		[[storage mutableString] replaceCharactersInRange:indentRange withString:newIndent];

		aRange.length += [newIndent length] - [indent length];

		if (!has_delta_offset)
		{
          		has_delta_offset = YES;
          		delta_offset = [newIndent length] - [indent length];
                }
		
		// get next line
		[self getLineStart:NULL end:&bol contentsEnd:NULL forLocation:bol];
		if (bol == NSNotFound)
			break;
	}
	[undoManager endUndoGrouping];
	return delta_offset;
}

- (void)increase_indent:(NSString *)characters
{
        NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
        [self changeIndentation:+1 inRange:NSMakeRange(bol, eol - bol)];
}

- (void)decrease_indent:(NSString *)characters
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol];
	[self changeIndentation:-1 inRange:NSMakeRange(bol, eol - bol)];
}

#pragma mark -
#pragma mark Undo support

- (void)undoDeleteOfString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	DEBUG(@"undoing delete of [%@] (%p) at %u", aString, aString, aLocation);
	[self insertString:aString atLocation:aLocation];
	final_location = aLocation;
	[self recordInsertInRange:NSMakeRange(aLocation, [aString length])];
}

- (void)undoInsertInRange:(NSRange)aRange
{
	NSString *deletedString = [[storage string] substringWithRange:aRange];
	[storage deleteCharactersInRange:aRange];
	final_location = aRange.location;
	[self recordDeleteOfString:deletedString atLocation:aRange.location];
}

- (void)recordInsertInRange:(NSRange)aRange
{
	// INFO(@"pushing insert of text in range %u+%u onto undo stack", aRange.location, aRange.length);
	[[undoManager prepareWithInvocationTarget:self] undoInsertInRange:aRange];
	[undoManager setActionName:@"insert text"];
}

- (void)recordDeleteOfString:(NSString *)aString atLocation:(NSUInteger)aLocation
{
	// INFO(@"pushing delete of [%@] (%p) at %u onto undo stack", aString, aString, aLocation);
	[[undoManager prepareWithInvocationTarget:self] undoDeleteOfString:aString atLocation:aLocation];
	[undoManager setActionName:@"delete text"];
}

- (void)recordDeleteOfRange:(NSRange)aRange
{
	NSString *s = [[storage string] substringWithRange:aRange];
	[self recordDeleteOfString:s atLocation:aRange.location];
}

- (void)recordReplacementOfRange:(NSRange)aRange withLength:(NSUInteger)aLength
{
	[undoManager beginUndoGrouping];
	[self recordDeleteOfRange:aRange];
	[self recordInsertInRange:NSMakeRange(aRange.location, aLength)];
	[undoManager endUndoGrouping];
}

#pragma mark -
#pragma mark Buffers

- (void)yankToBuffer:(unichar)bufferName append:(BOOL)appendFlag range:(NSRange)yankRange
{
	// get the unnamed buffer
	NSMutableString *buffer = [buffers objectForKey:@"unnamed"];
	if (buffer == nil)
	{
		buffer = [[NSMutableString alloc] init];
		[buffers setObject:buffer forKey:@"unnamed"];
	}

	[buffer setString:[[storage string] substringWithRange:yankRange]];
}

- (void)cutToBuffer:(unichar)bufferName append:(BOOL)appendFlag range:(NSRange)cutRange
{
	[self recordDeleteOfRange:cutRange];
	[self yankToBuffer:bufferName append:appendFlag range:cutRange];
	[storage deleteCharactersInRange:cutRange];
}

#pragma mark -
#pragma mark Convenience methods

- (void)gotoColumn:(NSUInteger)column fromLocation:(NSUInteger)aLocation
{
	NSUInteger bol, eol;
	[self getLineStart:&bol end:NULL contentsEnd:&eol forLocation:aLocation];
	if(eol - bol > column)
		final_location = end_location = bol + column;
	else if(eol - bol > 1)
		final_location = end_location = eol - 1;
	else
		final_location = end_location = bol;
}

- (void)gotoLine:(NSUInteger)line column:(NSUInteger)column
{
	NSInteger bol = [self locationForStartOfLine:line];
	if(bol != -1)
	{
		[self gotoColumn:column fromLocation:bol];
		[self setCaret:final_location];
		[self scrollRangeToVisible:NSMakeRange(final_location, 0)];
	}
}

- (NSUInteger)skipCharactersInSet:(NSCharacterSet *)characterSet from:(NSUInteger)startLocation to:(NSUInteger)toLocation backward:(BOOL)backwardFlag
{
	NSString *s = [storage string];
	NSRange r = [s rangeOfCharacterFromSet:[characterSet invertedSet]
				       options:backwardFlag ? NSBackwardsSearch : 0
					 range:backwardFlag ? NSMakeRange(toLocation, startLocation - toLocation + 1) : NSMakeRange(startLocation, toLocation - startLocation)];
	if (r.location == NSNotFound)
		return backwardFlag ? toLocation : toLocation; // FIXME: this is strange...
	return r.location;
}

- (NSUInteger)skipCharactersInSet:(NSCharacterSet *)characterSet fromLocation:(NSUInteger)startLocation backward:(BOOL)backwardFlag
{
	return [self skipCharactersInSet:characterSet
				    from:startLocation
				      to:backwardFlag ? 0 : [storage length]
				backward:backwardFlag];
}

- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation toLocation:(NSUInteger)toLocation
{
	return [self skipCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
				    from:startLocation
				      to:toLocation
				backward:NO];
}

- (NSUInteger)skipWhitespaceFrom:(NSUInteger)startLocation
{
	return [self skipCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
			    fromLocation:startLocation
				backward:NO];
}

#pragma mark -
#pragma mark - Ex command support

- (void)parseAndExecuteExCommand:(NSString *)exCommandString
{
	if ([exCommandString length] > 0)
	{
		ExCommand *ex = [[ExCommand alloc] initWithString:exCommandString];
		// NSLog(@"got ex [%@], command = [%@], method = [%@]", ex, ex.command, ex.method);
		if (ex.command == NULL)
			[[self delegate] message:@"The %@ command is unknown.", ex.name];
		else
		{
			SEL selector = NSSelectorFromString([NSString stringWithFormat:@"%@:", ex.command->method]);
			if ([self respondsToSelector:selector])
				[self performSelector:selector withObject:ex];
			else
				[[self delegate] message:@"The %@ command is not implemented.", ex.name];
		}
	}
}

- (BOOL)ex_command:(ViCommand *)command
{
	[[self delegate] getExCommandForTextView:self selector:@selector(parseAndExecuteExCommand:)];
	return YES;
}

- (void)highlightFindMatch:(OGRegularExpressionMatch *)match
{
	[self showFindIndicatorForRange:[match rangeOfMatchedString]];
}

- (BOOL)findPattern:(NSString *)pattern
	    options:(unsigned)find_options
         regexpType:(OgreSyntax)regexpSyntax
   ignoreLastRegexp:(BOOL)ignoreLastRegexp
{
	unsigned rx_options = OgreNotBOLOption | OgreNotEOLOption;
	if ([[NSUserDefaults standardUserDefaults] integerForKey:@"ignorecase"] == NSOnState)
		rx_options |= OgreIgnoreCaseOption;

	OGRegularExpression *lastSearchRegexp = [[NSApp delegate] lastSearchRegexp];
	NSString *lastSearchPattern = [[NSApp delegate] lastSearchPattern];
	if (![lastSearchPattern isEqualToString:pattern])
	{
		lastSearchRegexp = nil;
	}

	if (lastSearchRegexp == nil || ignoreLastRegexp)
	{
		/* compile the pattern regexp */
		@try
		{
			lastSearchRegexp = [OGRegularExpression regularExpressionWithString:pattern
										    options:rx_options
										     syntax:regexpSyntax
									    escapeCharacter:OgreBackslashCharacter];
		}
		@catch(NSException *exception)
		{
			INFO(@"***** FAILED TO COMPILE REGEXP ***** [%@], exception = [%@]", pattern, exception);
			[[self delegate] message:@"Invalid search pattern: %@", exception];
			return NO;
		}

		[[NSApp delegate] setLastSearchPattern:pattern];
		[[NSApp delegate] setLastSearchRegexp:lastSearchRegexp];
	}

	NSArray *foundMatches = [lastSearchRegexp allMatchesInString:[storage string] options:rx_options];

	if ([foundMatches count] == 0)
	{
		[[self delegate] message:@"Pattern not found"];
	}
	else
	{
		OGRegularExpressionMatch *match, *nextMatch = nil;
		for (match in foundMatches)
		{
			NSRange r = [match rangeOfMatchedString];
			if (find_options == 0)
			{
				if (nextMatch == nil && r.location > start_location)
					nextMatch = match;
			}
			else if (r.location < start_location)
			{
				nextMatch = match;
			}
		}

		if (nextMatch == nil)
		{
			if (find_options == 0)
				nextMatch = [foundMatches objectAtIndex:0];
			else
				nextMatch = [foundMatches lastObject];

			[[self delegate] message:@"Search wrapped"];
		}

		if (nextMatch)
		{
			NSRange r = [nextMatch rangeOfMatchedString];
			[self scrollRangeToVisible:r];
			final_location = end_location = r.location;
			[self setCaret:final_location];
			[self performSelector:@selector(highlightFindMatch:) withObject:nextMatch afterDelay:0];
		}

		return YES;
	}

	return NO;
}

- (BOOL)findPattern:(NSString *)pattern options:(unsigned)find_options
{
	return [self findPattern:pattern options:find_options regexpType:OgreRubySyntax ignoreLastRegexp:NO];
}

- (void)find_forward_callback:(NSString *)pattern
{
	if ([self findPattern:pattern options:0])
	{
		[self setCaret:final_location];
	}
}

/* syntax: /regexp */
- (BOOL)find:(ViCommand *)command
{
	[[self delegate] getExCommandForTextView:self selector:@selector(find_forward_callback:)];
	// FIXME: this won't work as a motion command!
	// d/pattern will not work!
	return YES;
}

/* syntax: n */
- (BOOL)repeat_find:(ViCommand *)command
{
	NSString *pattern = [[NSApp delegate] lastSearchPattern];
	if (pattern == nil)
	{
		[[self delegate] message:@"No previous search pattern"];
		return NO;
	}

	return [self findPattern:pattern options:0];
}

/* syntax: N */
- (BOOL)repeat_find_backward:(ViCommand *)command
{
	NSString *pattern = [[NSApp delegate] lastSearchPattern];
	if (pattern == nil)
	{
		[[self delegate] message:@"No previous search pattern"];
		return NO;
	}

	return [self findPattern:pattern options:1];
}

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
	if([theEvent type] != NSKeyDown && [theEvent type] != NSKeyUp)
		return NO;

	if([theEvent type] == NSKeyUp)
	{
		DEBUG(@"Got a performKeyEquivalent event, characters: '%@', keycode = %u, modifiers = 0x%04X",
		      [theEvent charactersIgnoringModifiers],
		      [[theEvent characters] characterAtIndex:0],
		      [theEvent modifierFlags]);
		return YES;
	}

	return [super performKeyEquivalent:theEvent];
}

/*
 * NSAlphaShiftKeyMask = 1 << 16,  (Caps Lock)
 * NSShiftKeyMask      = 1 << 17,
 * NSControlKeyMask    = 1 << 18,
 * NSAlternateKeyMask  = 1 << 19,
 * NSCommandKeyMask    = 1 << 20,
 * NSNumericPadKeyMask = 1 << 21,
 * NSHelpKeyMask       = 1 << 22,
 * NSFunctionKeyMask   = 1 << 23,
 * NSDeviceIndependentModifierFlagsMask = 0xffff0000U
 */

- (void)setCaret:(NSUInteger)location
{
	[self setSelectedRange:NSMakeRange(location, 0)];
}

- (NSUInteger)caret
{
	return [self selectedRange].location;
}

- (void)setCommandMode
{
	mode = ViCommandMode;
}

- (void)setInsertMode:(ViCommand *)command
{
	if (command.text)
	{
		[self insertString:command.text atLocation:end_location];
		final_location = end_location + [command.text length];
		[self recordInsertInRange:NSMakeRange(end_location, [command.text length])];

		 // simulate 'escape' (back to command mode)
		start_location = final_location;
		[self move_left:nil];
		
		if (hasBeginUndoGroup)
		{
                        [undoManager endUndoGrouping];
                        hasBeginUndoGroup = NO;
		}
	}
	else
	{
		// NSLog(@"entering insert mode at location %u", end_location);
		mode = ViInsertMode;
		insert_start_location = insert_end_location = end_location;
	}
}

- (void)evaluateCommand:(ViCommand *)command
{
	/* Default start- and end-location is the current location. */
	start_location = [self caret];
	end_location = start_location;
	final_location = start_location;

	if(command.motion_method)
	{
		/* The command has an associated motion component.
		 * Run the motion method and record the start and end locations.
		 */
		if([self performSelector:NSSelectorFromString(command.motion_method) withObject:command] == NO)
		{
			/* the command failed */
			[command reset];
			final_location = start_location;
			return;
		}
	}

	/* Find out the affected range for this command */
	NSUInteger l1 = start_location, l2 = end_location;
	if(l2 < l1)
	{	/* swap if end < start */
		l2 = l1;
		l1 = end_location;
	}
	//NSLog(@"affected locations: %u -> %u (%u chars)", l1, l2, l2 - l1);

	if(command.line_mode && !command.ismotion)
	{
		/* if this command is line oriented, extend the affectedRange to whole lines */
		NSUInteger bol, end;

		[self getLineStart:&bol end:&end contentsEnd:NULL forLocation:l1];

		if(!command.motion_method)
		{
			/* This is a "doubled" command (like dd or yy).
			 * A count, or motion-count, affects that number of whole lines.
			 */
			int line_count = command.count;
			if(line_count == 0)
				line_count = command.motion_count;
			while(--line_count > 0)
			{
				l2 = end;
				[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:l2];
			}
		}
		else
		{
			[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:l2];
		}

		l1 = bol;
		l2 = end;
		DEBUG(@"after line mode correction: affected locations: %u -> %u (%u chars)", l1, l2, l2 - l1);

#if 0
		/* If a line mode range includes the last line, also include the newline before the first line.
		 * This way delete doesn't leave an empty line.
		 */
		if(l2 == [storage length])
		{
			l1 = IMAX(0, l1 - 1);	// FIXME: what about using CRLF at end-of-lines?
			DEBUG(@"after including newline before first line: affected locations: %u -> %u (%u chars)", l1, l2, l2 - l1);
		}
#endif
	}
	affectedRange = NSMakeRange(l1, l2 - l1);

	BOOL ok = (NSUInteger)[self performSelector:NSSelectorFromString(command.method) withObject:command];
	if(ok && command.line_mode && !command.ismotion && (command.key != 'y' || command.motion_key != 'y') && command.key != '>' && command.key != '<')
	{
		/* For line mode operations, we always end up at the beginning of the line. */
		/* ...well, except for yy :-) */
		/* ...and > */
		/* ...and < */
		// FIXME: this is not a generic case!
		NSUInteger bol;
		[self getLineStart:&bol end:NULL contentsEnd:NULL forLocation:final_location];
		final_location = bol;
	}
}

- (void)input_newline:(NSString *)characters
{
	int num_chars = [self insertNewlineAtLocation:start_location indentForward:YES];
	[self setCaret:start_location + num_chars];
}

- (BOOL)parseSnippetPlaceholder:(NSString *)s length:(size_t *)length_ptr meta:(NSMutableDictionary *)meta
{
        NSScanner *scan = [NSScanner scannerWithString:s];

	NSMutableCharacterSet *shellVariableSet = [[NSMutableCharacterSet alloc] init];
	[shellVariableSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithRange:NSMakeRange('a', 'z' - 'a')]];
	[shellVariableSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithRange:NSMakeRange('A', 'Z' - 'A')]];
	[shellVariableSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];

	INFO(@"parsing placeholder [%@]", s);

	BOOL bracedExpression = NO;
	if ([scan scanString:@"{" intoString:nil])
		bracedExpression = YES;
                
        int tabStop;
        if ([scan scanInt:&tabStop])
        {
                [meta setObject:[NSNumber numberWithInt:tabStop] forKey:@"tabStop"];
        }
        else
        {
                NSString *var;
                [scan scanCharactersFromSet:shellVariableSet intoString:&var];
                [meta setObject:var forKey:@"variable"];
        }

	if (bracedExpression)
	{
                if ([scan scanString:@":" intoString:nil])
                {
                        // got a default value
                        NSString *defval;
                        [scan scanUpToString:@"}" intoString:&defval];
                        [meta setObject:defval forKey:@"defaultValue"];
                }
                else if ([scan scanString:@"/" intoString:nil])
                {
                        // got a regular expression transformation
                        NSString *regexp;
                        [scan scanUpToString:@"}" intoString:&regexp];
                        [meta setObject:regexp forKey:@"transformation"];
                }

                if (![scan scanString:@"}" intoString:nil])
                {
                        // parse error
                        return NO;
                }
	}

	*length_ptr = [scan scanLocation];
	
	return YES;
}

- (void)insertSnippet:(NSString *)snippet atLocation:(NSUInteger)aLocation
{
        NSMutableString *s = [[NSMutableString alloc] initWithString:snippet];

	BOOL foundMarker;
	NSUInteger i;
	do
        {
                INFO(@"parsing markers, s = [%@]", s);
                foundMarker = NO;
                for (i = 0; i < [s length]; i++)
                {
                        // FIXME: handle escapes
                        if ([s characterAtIndex:i] == '$')
                        {
                                size_t len;
                                NSMutableDictionary *meta = [[NSMutableDictionary alloc] init];
                                if (![self parseSnippetPlaceholder:[s substringFromIndex:i + 1] length:&len meta:meta])
                                	break;

                                // fixme: add (relative) location to meta
                                
                                if ([meta objectForKey:@"defaultValue"])
                                        [s replaceCharactersInRange:NSMakeRange(i, len + 1) withString:[meta objectForKey:@"defaultValue"]];
                                else
                                        [s deleteCharactersInRange:NSMakeRange(i, len + 1)];

                                foundMarker = YES;
                                break;
                        }
                }
        } while (foundMarker);

        // FIXME: inefficient(?)
        for (i = 0; i < [s length]; i++)
        {
                if ([s characterAtIndex:i] == '\n')
                {
                        aLocation += [self insertNewlineAtLocation:aLocation indentForward:YES];
                }
                else
                {
                        [self insertString:[s substringWithRange:NSMakeRange(i, 1)] atLocation:aLocation];
                        insert_end_location++;
                        aLocation++;
                }
        }
}

- (void)input_tab:(NSString *)characters
{
        // check for a tab trigger
        if (start_location > 0)
        {
                // is there a word before the cursor that we just typed?
                NSString *word = [self wordAtLocation:start_location - 1];
                if ([word length] > 0 && (insert_end_location - insert_start_location) >= [word length])
                {
                        NSArray *scopes = [self scopesAtLocation:start_location];
                        if (scopes)
                        {
                                NSString *snippetString = [[ViLanguageStore defaultStore] tabTrigger:word matchingScopes:scopes];
                                if (snippetString)
                                {
                                        [storage deleteCharactersInRange:NSMakeRange(start_location - [word length], [word length])];
                                        insert_end_location -= [word length];
                                        [self insertSnippet:snippetString atLocation:start_location - [word length]];
                                        return;
                                }
                        }
                }
        }
        
	// otherwise just insert a tab
	[self insertString:@"\t" atLocation:start_location];
        insert_end_location += 1;
}

- (NSArray *)smartTypingPairsAtLocation:(NSUInteger)aLocation
{
	NSDictionary *smartTypingPairs = [[ViLanguageStore defaultStore] preferenceItems:@"smartTypingPairs"];
	NSString *bestMatchingScope = [self bestMatchingScope:[smartTypingPairs allKeys] atLocation:aLocation];

	if (bestMatchingScope)
	{
		DEBUG(@"found smart typing pair scope selector [%@] at location %i", bestMatchingScope, aLocation);
		return [smartTypingPairs objectForKey:bestMatchingScope];
	}

	return nil;
}

- (void)input_backspace:(NSString *)characters
{
	if(start_location == insert_start_location)
	{
		[[self delegate] message:@"No more characters to erase"];
		return;
	}

	/* check if we're deleting the first character in a smart pair */
	NSArray *smartTypingPairs = [self smartTypingPairsAtLocation:start_location - 1];
	NSArray *pair;
	for(pair in smartTypingPairs)
	{
		if([[pair objectAtIndex:0] isEqualToString:[[storage string] substringWithRange:NSMakeRange(start_location - 1, 1)]] &&
		   [[pair objectAtIndex:1] isEqualToString:[[storage string] substringWithRange:NSMakeRange(start_location, 1)]])
		{
			[storage deleteCharactersInRange:NSMakeRange(start_location - 1, 2)];
			insert_end_location -= 2;
			[self setCaret:start_location - 1];
			return;
		}
	}

	/* else a regular character, just delete it */
	[storage deleteCharactersInRange:NSMakeRange(start_location - 1, 1)];
	insert_end_location--;

	[self setCaret:start_location - 1];
}

- (void)input_forward_delete:(NSString *)characters
{
	if(start_location >= insert_end_location)
	{
		[[self delegate] message:@"No more characters to erase"];
		return;
	}

	/* FIXME: should handle smart typing pairs here when we support arrow keys(?) in input mode
	 */

	[storage deleteCharactersInRange:NSMakeRange(start_location, 1)];
	insert_end_location--;
}

- (void)addTemporaryAttribute:(NSDictionary *)what
{
        [[self layoutManager] addTemporaryAttribute:[what objectForKey:@"attributeName"]
                                              value:[what objectForKey:@"value"]
                                  forCharacterRange:[[what objectForKey:@"range"] rangeValue]];
}

/* Input a character from the user (in insert mode). Handle smart typing pairs.
 * FIXME: assumes smart typing pairs are single characters.
 */
- (void)inputCharacters:(NSString *)characters
{
	BOOL foundSmartTypingPair = NO;
	NSArray *smartTypingPairs = [self smartTypingPairsAtLocation:start_location];
	if (smartTypingPairs)
	{
		NSArray *pair;
		for (pair in smartTypingPairs)
		{
			// check if we're inserting the end character of a smart typing pair
			// if so, just overwrite the end character
			if ([[pair objectAtIndex:1] isEqualToString:characters] &&
			    [[[storage string] substringWithRange:NSMakeRange(start_location, 1)] isEqualToString:[pair objectAtIndex:1]])
			{
                                if ([[self layoutManager] temporaryAttribute:ViSmartPairAttributeName
							    atCharacterIndex:start_location
							      effectiveRange:NULL])
				{
                                        foundSmartTypingPair = YES;
                                        [self setCaret:start_location + 1];
                                }
				break;
			}
			// check for the start character of a smart typing pair
			else if ([[pair objectAtIndex:0] isEqualToString:characters])
			{
				// don't use it if next character is alphanumeric
				if (!(start_location >= [storage length] ||
				      [[NSCharacterSet alphanumericCharacterSet] characterIsMember:[[storage string] characterAtIndex:start_location]]))
				{
					foundSmartTypingPair = YES;
					[self insertString:[pair objectAtIndex:0] atLocation:start_location];
					[self insertString:[pair objectAtIndex:1] atLocation:start_location + 1];
					
					// INFO(@"adding smart pair attr to %u + 2", start_location);
					// [[self layoutManager] addTemporaryAttribute:ViSmartPairAttributeName value:characters forCharacterRange:NSMakeRange(start_location, 2)];
                                        [self performSelector:@selector(addTemporaryAttribute:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                        	ViSmartPairAttributeName, @"attributeName",
                                        	characters, @"value",
                                        	[NSValue valueWithRange:NSMakeRange(start_location, 2)], @"range",
                                        	nil] afterDelay:0];

					insert_end_location += 2;
					[self setCaret:start_location + 1];
					break;
				}
			}
		}
	}
	
	if (!foundSmartTypingPair)
	{
		[self insertString:characters atLocation:start_location];
		insert_end_location += [characters length];
		[self setCaret:start_location + [characters length]];
	}
}

- (void)keyDown:(NSEvent *)theEvent
{
#if 1
	NSLog(@"Got a keyDown event, characters: '%@', keycode = 0x%04X, code = 0x%08X",
	      [theEvent characters],
	      [theEvent keyCode],
              ([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask) | [theEvent keyCode]);
	      
#endif

	if ([[theEvent characters] length] == 0)
		return [super keyDown:theEvent];
	unichar charcode = [[theEvent characters] characterAtIndex:0];
	
	if (mode == ViInsertMode)
	{
		if (charcode == 0x1B)
		{
			/* escape, return to command mode */
			NSString *insertedText = [[storage string] substringWithRange:NSMakeRange(insert_start_location, insert_end_location - insert_start_location)];
			INFO(@"registering replay text: [%@] at %u + %u (length %u), count = %i",
				insertedText, insert_start_location, insert_end_location, [insertedText length], parser.count);

			/* handle counts for inserted text here */
			NSString *multipliedText = insertedText;
			if (parser.count > 1)
			{
				multipliedText = [insertedText stringByPaddingToLength:[insertedText length] * (parser.count - 1)
						                            withString:insertedText
							               startingAtIndex:0];
				[self insertString:multipliedText atLocation:[self caret]];

				multipliedText = [insertedText stringByPaddingToLength:[insertedText length] * parser.count
						                            withString:insertedText
							               startingAtIndex:0];
			}

			[parser setText:multipliedText];
			if ([multipliedText length] > 0)
				[self recordInsertInRange:NSMakeRange(insert_start_location, [multipliedText length])];
			if (hasBeginUndoGroup)
			{
                                [undoManager endUndoGrouping];
                                hasBeginUndoGroup = NO;
                        }
			[self setCommandMode];
			start_location = end_location = [self caret];
			[self move_left:nil];
			[self setCaret:end_location];
		}
		else /* if((([theEvent modifierFlags] & ~(NSShiftKeyMask | NSAlphaShiftKeyMask | NSControlKeyMask | NSAlternateKeyMask)) >> 17) == 0) */
		{
			/* handle keys with no modifiers, or with shift, caps lock, control or alt modifier */

			// NSLog(@"insert text [%@], length = %u", [theEvent characters], [[theEvent characters] length]);
			start_location = [self caret];

			/* Lookup the key in the input command map. Some keys are handled specially, or trigger macros. */
			NSUInteger code = (([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask) | [theEvent keyCode]);
			NSString *inputCommand = [inputCommands objectForKey:[NSNumber numberWithUnsignedInteger:code]];
			if (inputCommand)
			{
				[self performSelector:NSSelectorFromString(inputCommand) withObject:[theEvent characters]];
			}
			else if ((([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask) & (NSCommandKeyMask | NSFunctionKeyMask)) == 0)
			{
				/* other keys insert themselves */
				/* but don't input control characters */
				if (([theEvent modifierFlags] & NSControlKeyMask) == NSControlKeyMask)
				{
					[[self delegate] message:@"Illegal character; quote to enter"];
				}
				else
				{
					[self inputCharacters:[theEvent characters]];
				}
			}
		}
	}
	else if (mode == ViCommandMode) // or normal mode
	{
		// check for a special key bound to a function
		NSUInteger code = (([theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask) | [theEvent keyCode]);
		NSString *normalCommand = [normalCommands objectForKey:[NSNumber numberWithUnsignedInteger:code]];
		if (normalCommand)
		{
			[self performSelector:NSSelectorFromString(normalCommand) withObject:[theEvent characters]];
		}
		else
		{
			if (parser.complete)
				[parser reset];

			[parser pushKey:charcode];
			if (parser.complete)
			{
				[[self delegate] message:@""]; // erase any previous message
				[storage beginEditing];
				[self evaluateCommand:parser];
				[storage endEditing];
				[self setCaret:final_location];
			}
		}
	}

        [self scrollRangeToVisible:NSMakeRange([self caret], 0)];
}

/* Takes a string of characters and creates key events for each one.
 * Then feeds them into the keyDown method to simulate key presses.
 * Only used for unit testing.
 */
- (void)input:(NSString *)inputString
{
	int i;
	for(i = 0; i < [inputString length]; i++)
	{
		NSEvent *ev = [NSEvent keyEventWithType:NSKeyDown
					       location:NSMakePoint(0, 0)
					  modifierFlags:0
					      timestamp:[[NSDate date] timeIntervalSinceNow]
					   windowNumber:0
						context:[NSGraphicsContext currentContext]
					     characters:[inputString substringWithRange:NSMakeRange(i, 1)]
			    charactersIgnoringModifiers:[inputString substringWithRange:NSMakeRange(i, 1)]
					      isARepeat:NO
						keyCode:[inputString characterAtIndex:i]];
		[self keyDown:ev];
	}
}




/* This is stolen from Smultron.
 */
- (void)drawRect:(NSRect)rect
{
	[super drawRect:rect];

	if (pageGuideX > 0)
	{
		NSRect bounds = [self bounds];
		if([self needsToDrawRect:NSMakeRect(pageGuideX, 0, 1, bounds.size.height)] == YES)
		{ // So that it doesn't draw the line if only e.g. the cursor updates
			[[self insertionPointColor] set];
			// pageGuideColour = [color colorWithAlphaComponent:([color alphaComponent] / 4)];
			[NSBezierPath strokeRect:NSMakeRect(pageGuideX, 0, 0, bounds.size.height)];
		}
	}
}

- (void)setPageGuide:(int)pageGuideValue
{
	if (pageGuideValue == 0)
	{
		pageGuideX = 0;
	}
	else
	{
		NSDictionary *sizeAttribute = [[NSDictionary alloc] initWithObjectsAndKeys:[self font], NSFontAttributeName, nil];
		CGFloat sizeOfCharacter = [@" " sizeWithAttributes:sizeAttribute].width;
		pageGuideX = (sizeOfCharacter * (pageGuideValue + 1)) - 1.5;
		// -1.5 to put it between the two characters and draw only on one pixel and
		// not two (as the system draws it in a special way), and that's also why the
		// width above is set to zero
	}
	[self display];
}

/* This one is from CocoaDev.
 */
- (void)disableWrapping
{
	const float LargeNumberForText = 1.0e7;
	
	NSScrollView *scrollView = [self enclosingScrollView];
	[scrollView setHasVerticalScroller:YES];
	[scrollView setHasHorizontalScroller:YES];
	[scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

	NSTextContainer *textContainer = [self textContainer];
	[textContainer setContainerSize:NSMakeSize(LargeNumberForText, LargeNumberForText)];
	[textContainer setWidthTracksTextView:NO];
	[textContainer setHeightTracksTextView:NO];

	[self setMaxSize:NSMakeSize(LargeNumberForText, LargeNumberForText)];
	[self setHorizontallyResizable:YES];
	[self setVerticallyResizable:YES];
	[self setAutoresizingMask:NSViewNotSizable];
}

- (void)setTheme:(ViTheme *)aTheme
{
	theme = aTheme;
	[self setBackgroundColor:[theme backgroundColor]];
	[self setDrawsBackground:YES];
	[self setInsertionPointColor:[theme caretColor]];
	[self setSelectedTextAttributes:[NSDictionary dictionaryWithObject:[theme selectionColor]
								    forKey:NSBackgroundColorAttributeName]];
	[self setTabSize:[[NSUserDefaults standardUserDefaults] integerForKey:@"tabstop"]];
}

- (NSFont *)font
{
	return [NSFont userFixedPitchFontOfSize:12.0];
}

- (void)setTabSize:(int)tabSize
{
	NSString *tab = [@"" stringByPaddingToLength:tabSize withString:@" " startingAtIndex:0];

	NSDictionary *attrs = [NSDictionary dictionaryWithObject:[self font] forKey:NSFontAttributeName];
	NSSize tabSizeInPoints = [tab sizeWithAttributes:attrs];

	NSMutableParagraphStyle *style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];

	// remove all previous tab stops
	NSTextTab *tabStop;
	for (tabStop in [style tabStops])
	{
		[style removeTabStop:tabStop];
	}

	// "Tabs after the last specified in tabStops are placed at integral multiples of this distance."
	[style setDefaultTabInterval:tabSizeInPoints.width];

	attrs = [NSDictionary dictionaryWithObject:style forKey:NSParagraphStyleAttributeName];
	[self setTypingAttributes:attrs];
	[storage addAttributes:attrs range:NSMakeRange(0, [[storage string] length])];
}

- (NSUndoManager *)undoManager
{
	return undoManager;
}

- (NSInteger)locationForStartOfLine:(NSUInteger)aLineNumber
{
	int line = 1;
	NSInteger location = 0;
	while(line < aLineNumber)
	{
		NSUInteger end;
		[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:location];
		if(location == end)
		{
			return -1;
		}
		location = end;
		line++;
	}
	
	return location;
}

- (NSUInteger)lineNumberAtLocation:(NSUInteger)aLocation
{
	int line = 1;
	NSUInteger location = 0;
	while(location < aLocation)
	{
		NSUInteger bol, end;
		[self getLineStart:&bol end:&end contentsEnd:NULL forLocation:location];
		if(end > aLocation)
		{
			break;
		}
		location = end;
		line++;
	}
	
	return line;
}

- (NSUInteger)currentLine
{
	return [self lineNumberAtLocation:[self caret]];
}

- (NSUInteger)currentColumn
{
	NSUInteger bol, end;
	[self getLineStart:&bol end:&end contentsEnd:NULL forLocation:[self caret]];
	return [self caret] - bol;
}

- (NSString *)wordAtLocation:(NSUInteger)aLocation
{
	NSUInteger word_start = [self skipCharactersInSet:wordSet fromLocation:aLocation backward:YES];
	if (word_start < aLocation && word_start > 0)
		word_start += 1;

	NSUInteger word_end = [self skipCharactersInSet:wordSet fromLocation:aLocation backward:NO];
	if (word_end > word_start)
	{
		return [[storage string] substringWithRange:NSMakeRange(word_start, word_end - word_start)];
	}

	return nil;
}

- (void)show_scope:(NSString *)characters
{
	NSArray *scopes = [[self layoutManager] temporaryAttribute:ViScopeAttributeName
							    atCharacterIndex:[self caret]
							      effectiveRange:NULL];
	[[self delegate] message:[scopes componentsJoinedByString:@" "]];
}

@end
