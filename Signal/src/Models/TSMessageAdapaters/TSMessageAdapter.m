//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "AttachmentSharing.h"
#import "OWSCall.h"
#import "Signal-Swift.h"
#import "TSAttachmentPointer.h"
#import "TSAttachmentStream.h"
#import "TSCall.h"
#import "TSContactThread.h"
#import "TSContentAdapters.h"
#import "TSErrorMessage.h"
#import "TSGenericAttachmentAdapter.h"
#import "TSGroupThread.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSOutgoingMessage.h"
#import <MobileCoreServices/MobileCoreServices.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSMessageAdapter ()

// ---

@property (nonatomic, retain) TSContactThread *thread;

// OR for groups

@property (nonatomic, copy) NSString *senderId;
@property (nonatomic, copy) NSString *senderDisplayName;

// for InfoMessages

@property TSInfoMessageType infoMessageType;

// for ErrorMessages

@property TSErrorMessageType errorMessageType;

// for outgoing Messages only

@property NSInteger outgoingMessageStatus;

// for MediaMessages

@property JSQMediaItem<OWSMessageEditing> *mediaItem;


// -- Redeclaring properties from OWSMessageData protocol to synthesize variables
@property (nonatomic) TSMessageAdapterType messageType;
@property (nonatomic) BOOL isExpiringMessage;
@property (nonatomic) BOOL shouldStartExpireTimer;
@property (nonatomic) uint64_t expiresAtSeconds;
@property (nonatomic) uint32_t expiresInSeconds;

@property (nonatomic, copy) NSDate *messageDate;
@property (nonatomic, retain) NSString *messageBody;

@property NSUInteger identifier;

@end

#pragma mark -

@implementation TSMessageAdapter

- (instancetype)initWithInteraction:(TSInteraction *)interaction
{
    self = [super init];
    if (!self) {
        return self;
    }

    _interaction = interaction;
    _messageDate = interaction.date;
    // TODO casting a string to an integer? At least need a comment here explaining why we are doing this.
    // Can we just remove this? Haven't found where we're using it...
    _identifier = (NSUInteger)interaction.uniqueId;

    if ([interaction isKindOfClass:[TSMessage class]]) {
        TSMessage *message = (TSMessage *)interaction;
        _isExpiringMessage = message.isExpiringMessage;
        _expiresAtSeconds = message.expiresAt / 1000;
        _expiresInSeconds = message.expiresInSeconds;
        _shouldStartExpireTimer = message.shouldStartExpireTimer;
    } else {
        _isExpiringMessage = NO;
    }

    return self;
}

+ (id<OWSMessageData>)messageViewDataWithInteraction:(TSInteraction *)interaction inThread:(TSThread *)thread contactsManager:(id<ContactsManagerProtocol>)contactsManager
{
    TSMessageAdapter *adapter = [[TSMessageAdapter alloc] initWithInteraction:interaction];

    if ([thread isKindOfClass:[TSContactThread class]]) {
        adapter.thread = (TSContactThread *)thread;
        if ([interaction isKindOfClass:[TSIncomingMessage class]]) {
            NSString *contactId       = ((TSContactThread *)thread).contactIdentifier;
            adapter.senderId          = contactId;
            adapter.senderDisplayName = [contactsManager displayNameForPhoneIdentifier:contactId];
            adapter.messageType       = TSIncomingMessageAdapter;
        } else {
            adapter.senderId          = ME_MESSAGE_IDENTIFIER;
            adapter.senderDisplayName = NSLocalizedString(@"ME_STRING", @"");
            adapter.messageType       = TSOutgoingMessageAdapter;
        }
    } else if ([thread isKindOfClass:[TSGroupThread class]]) {
        if ([interaction isKindOfClass:[TSIncomingMessage class]]) {
            TSIncomingMessage *message = (TSIncomingMessage *)interaction;
            adapter.senderId           = message.authorId;
            adapter.senderDisplayName = [contactsManager displayNameForPhoneIdentifier:message.authorId];
            adapter.messageType        = TSIncomingMessageAdapter;
        } else {
            adapter.senderId          = ME_MESSAGE_IDENTIFIER;
            adapter.senderDisplayName = NSLocalizedString(@"ME_STRING", @"");
            adapter.messageType       = TSOutgoingMessageAdapter;
        }
    }

    if ([interaction isKindOfClass:[TSIncomingMessage class]] ||
        [interaction isKindOfClass:[TSOutgoingMessage class]]) {
        TSMessage *message  = (TSMessage *)interaction;
        adapter.messageBody = [[DisplayableTextFilter new] displayableText:message.body];

        if ([message hasAttachments]) {
            for (NSString *attachmentID in message.attachmentIds) {
                TSAttachment *attachment = [TSAttachment fetchObjectWithUniqueID:attachmentID];

                BOOL isIncomingAttachment = [interaction isKindOfClass:[TSIncomingMessage class]];

                if ([attachment isKindOfClass:[TSAttachmentStream class]]) {
                    TSAttachmentStream *stream = (TSAttachmentStream *)attachment;
                    if ([attachment.contentType isEqualToString:OWSMimeTypeOversizeTextMessage]) {
                        NSData *textData = [NSData dataWithContentsOfURL:stream.mediaURL];
                        NSString *fullText = [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
                        // Only show up to 2kb of text.
                        const NSUInteger kMaxTextDisplayLength = 2 * 1024;
                        NSString *displayText = [[DisplayableTextFilter new] displayableText:fullText];
                        if (displayText.length > kMaxTextDisplayLength) {
                            // Trim whitespace before _AND_ after slicing the snipper from the string.
                            NSString *snippet =
                                [[[displayText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                                    substringWithRange:NSMakeRange(0, kMaxTextDisplayLength)]
                                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            displayText =
                                [NSString stringWithFormat:NSLocalizedString(@"OVERSIZE_TEXT_DISPLAY_FORMAT",
                                                               @"A display format for oversize text messages."),
                                          snippet];
                        }
                        adapter.messageBody = displayText;
                    } else if ([stream isAnimated]) {
                        adapter.mediaItem =
                            [[TSAnimatedAdapter alloc] initWithAttachment:stream incoming:isIncomingAttachment];
                        adapter.mediaItem.appliesMediaViewMaskAsOutgoing = !isIncomingAttachment;
                        break;
                    } else if ([stream isImage]) {
                        adapter.mediaItem =
                            [[TSPhotoAdapter alloc] initWithAttachment:stream incoming:isIncomingAttachment];
                        adapter.mediaItem.appliesMediaViewMaskAsOutgoing = !isIncomingAttachment;
                        break;
                    } else if ([stream isVideo] || [stream isAudio]) {
                        adapter.mediaItem = [[TSVideoAttachmentAdapter alloc]
                            initWithAttachment:stream
                                      incoming:[interaction isKindOfClass:[TSIncomingMessage class]]];
                        adapter.mediaItem.appliesMediaViewMaskAsOutgoing = !isIncomingAttachment;
                        break;
                    } else {
                        adapter.mediaItem = [[TSGenericAttachmentAdapter alloc]
                            initWithAttachment:stream
                                      incoming:[interaction isKindOfClass:[TSIncomingMessage class]]];
                        adapter.mediaItem.appliesMediaViewMaskAsOutgoing = !isIncomingAttachment;
                        break;
                    }
                } else if ([attachment isKindOfClass:[TSAttachmentPointer class]]) {
                    TSAttachmentPointer *pointer = (TSAttachmentPointer *)attachment;
                    adapter.messageType          = TSInfoMessageAdapter;

                    switch (pointer.state) {
                        case TSAttachmentPointerStateEnqueued:
                            adapter.messageBody = NSLocalizedString(@"ATTACHMENT_QUEUED", nil);
                            break;
                        case TSAttachmentPointerStateDownloading:
                            adapter.messageBody = NSLocalizedString(@"ATTACHMENT_DOWNLOADING", nil);
                            break;
                        case TSAttachmentPointerStateFailed:
                            adapter.messageBody = NSLocalizedString(@"ATTACHMENT_DOWNLOAD_FAILED", nil);
                            break;
                    }
                } else {
                    DDLogError(@"We retrieved an attachment that doesn't have a known type : %@",
                               NSStringFromClass([attachment class]));
                }
            }
        }
    } else if ([interaction isKindOfClass:[TSCall class]]) {
        TSCall *callRecord = (TSCall *)interaction;
        return [[OWSCall alloc] initWithCallRecord:callRecord];
    } else if ([interaction isKindOfClass:[TSInfoMessage class]]) {
        TSInfoMessage *infoMessage = (TSInfoMessage *)interaction;
        adapter.infoMessageType    = infoMessage.messageType;
        adapter.messageBody        = infoMessage.description;
        adapter.messageType        = TSInfoMessageAdapter;
        if (adapter.infoMessageType == TSInfoMessageTypeGroupQuit ||
            adapter.infoMessageType == TSInfoMessageTypeGroupUpdate) {
            // repurposing call display for info message stuff for group updates, ! adapter will know because the date
            // is nil.
            //
            // TODO: I suspect that we'll want a separate model
            //       that conforms to <OWSMessageData> for info
            //       messages.
            CallStatus status = 0;
            if (adapter.infoMessageType == TSInfoMessageTypeGroupQuit) {
                status = kGroupUpdateLeft;
            } else if (adapter.infoMessageType == TSInfoMessageTypeGroupUpdate) {
                status = kGroupUpdate;
            }
            OWSCall *call = [[OWSCall alloc] initWithInteraction:interaction
                                                        callerId:@""
                                               callerDisplayName:adapter.messageBody
                                                            date:nil
                                                          status:status
                                                   displayString:@""];
            return call;
        }
    } else {
        TSErrorMessage *errorMessage = (TSErrorMessage *)interaction;
        adapter.errorMessageType = errorMessage.errorType;
        adapter.messageBody          = errorMessage.description;
        adapter.messageType          = TSErrorMessageAdapter;
    }

    if ([interaction isKindOfClass:[TSOutgoingMessage class]]) {
        adapter.outgoingMessageStatus = ((TSOutgoingMessage *)interaction).messageState;
    }

    return adapter;
}

- (NSString *)senderId {
    if (_senderId) {
        return _senderId;
    } else {
        return ME_MESSAGE_IDENTIFIER;
    }
}

- (NSDate *)date {
    return self.messageDate;
}

#pragma mark - OWSMessageEditing Protocol

- (BOOL)canPerformEditingAction:(SEL)action
{
    if ([self attachmentStream] && ![self attachmentStream].isUploaded) {
        return NO;
    }

    // Deletes are always handled by TSMessageAdapter
    if (action == @selector(delete:)) {
        return YES;
    }

    // Delegate other actions for media items
    if ([self attachmentStream] && action == NSSelectorFromString(@"share:")) {
        return YES;
    } else if (self.isMediaMessage) {
        return [self.mediaItem canPerformEditingAction:action];
    } else if (self.messageType == TSInfoMessageAdapter || self.messageType == TSErrorMessageAdapter) {
        return NO;
    } else {
        // Text message - no media attachment
        if (action == @selector(copy:)) {
            return YES;
        }
    }
    return NO;
}

- (void)performEditingAction:(SEL)action
{
    // Deletes are always handled by TSMessageAdapter
    if (action == @selector(delete:)) {
        DDLogDebug(@"Deleting interaction with uniqueId: %@", self.interaction.uniqueId);
        [self.interaction remove];
        return;
    } else if (action == NSSelectorFromString(@"share:")) {
        TSAttachmentStream *stream = [self attachmentStream];
        OWSAssert(stream);
        if (stream) {
            [AttachmentSharing showShareUIForAttachment:stream];
        }
        return;
    }


    // Delegate other actions for media items
    if (self.isMediaMessage) {
        [self.mediaItem performEditingAction:action];
        return;
    } else {
        // Text message - no media attachment
        if (action == @selector(copy:)) {
            UIPasteboard.generalPasteboard.string = self.messageBody;
            return;
        }
    }

    // Shouldn't get here, as only supported actions should be exposed via canPerformEditingAction
    NSString *actionString = NSStringFromSelector(action);
    DDLogError(@"'%@' action unsupported for TSInteraction: uniqueId=%@, mediaType=%@",
        actionString,
        self.interaction.uniqueId,
        [self.mediaItem class]);
    OWSAssert(NO);
}

- (TSAttachmentStream *)attachmentStream
{
    if (![self.interaction isKindOfClass:[TSMessage class]]) {
        return nil;
    }

    TSMessage *message = (TSMessage *)self.interaction;

    if (![message hasAttachments]) {
        return nil;
    }
    OWSAssert(message.attachmentIds.count <= 1);
    NSString *attachmentID = message.attachmentIds[0];
    TSAttachment *attachment = [TSAttachment fetchObjectWithUniqueID:attachmentID];

    if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
        return nil;
    }

    TSAttachmentStream *stream = (TSAttachmentStream *)attachment;
    return stream;
}

- (BOOL)isMediaMessage {
    return _mediaItem ? YES : NO;
}

- (id<JSQMessageMediaData>)media {
    return _mediaItem;
}

- (NSString *)text {
    return self.messageBody;
}

- (NSUInteger)messageHash
{
    if (self.isMediaMessage) {
        return [self.mediaItem mediaHash];
    } else {
        return self.identifier;
    }
}

- (NSInteger)messageState {
    return self.outgoingMessageStatus;
}

- (CGFloat)mediaViewAlpha
{
    return (CGFloat)(self.isMediaBeingSent ? 0.75 : 1);
}

- (BOOL)isMediaBeingSent
{
    if ([self.interaction isKindOfClass:[TSOutgoingMessage class]]) {
        TSOutgoingMessage *outgoingMessage = (TSOutgoingMessage *)self.interaction;
        if (outgoingMessage.hasAttachments && outgoingMessage.messageState == TSOutgoingMessageStateAttemptingOut) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Logging

+ (NSString *)tag
{
    return [NSString stringWithFormat:@"[%@]", self.class];
}

- (NSString *)tag
{
    return self.class.tag;
}

@end

NS_ASSUME_NONNULL_END
