#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <pthread.h>
#import <substrate.h>
#import <dlfcn.h>
#import "vosk_api.h"

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(int)cell edit:(Class)edit;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (NSString *)name;
- (void)setName:(NSString *)name;
@end

@interface PSViewController : UIViewController
- (PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
@end

@interface PLCustomListController : PSViewController
@end

// DictaKey: Skeuomorphic dictation key for iPad on iOS 6.
// Multilingual offline speech recognition via Vosk/Kaldi with baked OpenFST ConstFst graphs.
// Automatic keyboard inputMode tracking and PreferenceLoader settings integration.

@interface UIKeyboardImpl : UIView
@end

@interface DKButtonView : UIView
@property (nonatomic, copy) NSString *langCode;
@end

static void Reposition(void);
static void AbortOrStopRecording(BOOL isDismiss);

static void (*orig_ImpLayout)(id, SEL);
static void New_ImpLayout(id self, SEL _cmd) {
    orig_ImpLayout(self, _cmd);
    Reposition();
}
static void (*orig_LSLayout)(id, SEL);
static void New_LSLayout(id self, SEL _cmd) {
    orig_LSLayout(self, _cmd);
    Reposition();
}
static void (*orig_SetCurrentInputMode)(id, SEL, id);
static void New_SetCurrentInputMode(id self, SEL _cmd, id mode) {
    AbortOrStopRecording(YES);
    orig_SetCurrentInputMode(self, _cmd, mode);
    dispatch_async(dispatch_get_main_queue(), ^{
        Reposition();
    });
}

static int g_state = 0; // 0: idle, 1: recording, 2: finalizing
static UIView *g_btn = nil;
static UIView *g_owner = nil;

static VoskModel *g_model = nil;
static NSString *g_loadedModelLang = nil;
static VoskRecognizer *g_rec = nil;
static AudioUnit g_au = NULL;
static BOOL g_audioOn = NO;

static int g_partialLen = 0;
static NSString *g_lastPartial = @"";
static BOOL s_lastWasSpace = NO;

// ---- Settings (PreferenceLoader) ----
static BOOL g_prefEnabled = YES;

static void ReloadSettings(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.local.dictakey.plist"];
    if (prefs) {
        id v = [prefs objectForKey:@"enabled"];
        g_prefEnabled = v ? [v boolValue] : YES;
    }
}

// ---- SPSC Ring Buffer ----
#define RB_SIZE (4 * 1024 * 1024)
static char s_rb[RB_SIZE];
static volatile long s_rb_w = 0, s_rb_r = 0;
static volatile BOOL s_worker_quit = NO;
static volatile BOOL s_recording = NO;
static pthread_t s_worker = 0;
static BOOL s_workerAlive = NO;
static long g_cbCount = 0, g_cbBytes = 0, g_dropBytes = 0;

static void DBGLog(NSString *line) {
    NSString *old = [NSString stringWithContentsOfFile:
        @"/var/mobile/Library/dictakey.dbg" encoding:NSUTF8StringEncoding error:NULL];
    if ([old length] > 6000) old = @"";
    NSString *all = old ? [NSString stringWithFormat:@"%@\n%@", old, line] : line;
    [all writeToFile:@"/var/mobile/Library/dictakey.dbg"
          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void SetState(int s) {
    g_state = s;
    if (!g_btn) return;
    g_btn.backgroundColor = [UIColor clearColor];
    [g_btn setNeedsDisplay];
}

static void NotifyTextChange(id impl) {
    if (!impl) return;
    if ([impl respondsToSelector:@selector(updateReturnKey)])
        [impl performSelector:@selector(updateReturnKey)];
    id delegate = [impl respondsToSelector:@selector(delegate)] ? [impl performSelector:@selector(delegate)] : nil;
    if (delegate) {
        if ([delegate respondsToSelector:@selector(sendActionsForControlEvents:)])
            [delegate performSelector:@selector(sendActionsForControlEvents:) withObject:(id)(intptr_t)UIControlEventEditingChanged];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextFieldTextDidChangeNotification object:delegate];
    }
}

static void InsertText(NSString *text) {
    Class kb = objc_getClass("UIKeyboardImpl");
    id impl = [kb performSelector:@selector(sharedInstance)];
    if (impl && [impl respondsToSelector:@selector(insertText:)]) {
        [impl performSelector:@selector(insertText:) withObject:text];
        NotifyTextChange(impl);
    }
}

static void DeleteBack(int n) {
    Class kb = objc_getClass("UIKeyboardImpl");
    id impl = [kb performSelector:@selector(sharedInstance)];
    if (!impl) return;
    for (int i = 0; i < n; i++) {
        if ([impl respondsToSelector:@selector(deleteBackward)])
            [impl performSelector:@selector(deleteBackward)];
    }
    NotifyTextChange(impl);
}

static void ClearPartial(void) {
    int len = g_partialLen;
    g_partialLen = 0; g_lastPartial = @"";
    if (len > 0)
        dispatch_async(dispatch_get_main_queue(), ^{ DeleteBack(len); });
}

static NSString *JsonText(const char *json, NSString *key) {
    NSString *js = json ? [NSString stringWithUTF8String:json] : @"";
    NSString *needle = [NSString stringWithFormat:@"\"%@\" : \"", key];
    NSRange a = [js rangeOfString:needle];
    if (a.location == NSNotFound) return nil;
    NSString *tail = [js substringFromIndex:NSMaxRange(a)];
    NSRange b = [tail rangeOfString:@"\""];
    if (b.location == NSNotFound) return nil;
    return [tail substringToIndex:b.location];
}

// ---- Spoken Punctuation Mapping ----
static NSDictionary *PunctuationMapForLang(NSString *lang) {
    static NSDictionary *s_maps = nil;
    if (!s_maps) {
        s_maps = [@{
            @"ru": @{
                @"запятая": @",",
                @"двоеточие": @":",
                @"тире": @" —",
                @"дефис": @"-"
            },
            @"en": @{
                @"comma": @",",
                @"colon": @":",
                @"dash": @" —",
                @"hyphen": @"-"
            },
            @"uk": @{
                @"кома": @",",
                @"двокрапка": @":",
                @"тире": @" —",
                @"дефіс": @"-"
            },
            @"de": @{
                @"komma": @",",
                @"doppelpunkt": @":",
                @"gedankenstrich": @" —",
                @"bindestrich": @"-"
            },
            @"fr": @{
                @"virgule": @",",
                @"deux-points": @":",
                @"tiret": @" —"
            },
            @"es": @{
                @"coma": @",",
                @"dos puntos": @":",
                @"guion": @" —"
            },
            @"it": @{
                @"virgola": @",",
                @"due punti": @":",
                @"trattino": @" —"
            }
        } retain];
    }
    return [s_maps objectForKey:lang];
}

static NSString *ApplyPunctuation(NSString *text, NSString *lang) {
    if (!text.length) return text;
    NSDictionary *map = PunctuationMapForLang(lang);
    if (!map) return text;
    for (NSString *word in map) {
        NSString *punct = [map objectForKey:word];
        NSString *withSpace = [@" " stringByAppendingString:word];
        text = [text stringByReplacingOccurrencesOfString:withSpace withString:punct];
        if ([text isEqualToString:word]) text = punct;
    }
    return text;
}

// ---- Language and Model Resolution ----
static NSString *GetActiveKeyboardLang(void) {
    id mode = [UITextInputMode currentInputMode];
    NSString *lang = [mode respondsToSelector:@selector(primaryLanguage)] ?
        [mode performSelector:@selector(primaryLanguage)] : nil;
    if (!lang && [mode respondsToSelector:@selector(identifier)]) {
        lang = [mode performSelector:@selector(identifier)];
    }
    if (lang.length >= 2) {
        return [[lang substringToIndex:2] lowercaseString];
    }
    return @"ru";
}

static NSString *GetActiveDictationLang(void) {
    return GetActiveKeyboardLang();
}

static BOOL IsLangAllowed(NSString *lang) {
    if (!g_prefEnabled) return NO;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.local.dictakey.plist"];
    if (prefs) {
        NSString *k = [NSString stringWithFormat:@"lang_%@", lang];
        id v = [prefs objectForKey:k];
        if (v) return [v boolValue];
    }
    return YES;
}

static NSString *ModelPathForLang(NSString *lang) {
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/vosk/model-%@", lang];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir) {
        return path;
    }
    return nil;
}

static double s_lastActivityTime = 0;

static void FreeLoadedModel(void) {
    if (g_model) {
        vosk_model_free(g_model);
        g_model = NULL;
        [g_loadedModelLang release];
        g_loadedModelLang = nil;
        DBGLog(@"model freed from memory");
    }
}

static void EnsureModelLoadedForLang(NSString *lang) {
    static volatile BOOL s_loading = NO;
    if (s_loading) return;
    s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
    if (g_model && [g_loadedModelLang isEqualToString:lang]) return;
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    
    NSString *path = ModelPathForLang(lang);
    if (!path) return;
    
    s_loading = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        double t0 = [NSDate timeIntervalSinceReferenceDate];
        if (g_model) {
            vosk_model_free(g_model);
            g_model = NULL;
            [g_loadedModelLang release];
            g_loadedModelLang = nil;
        }
        g_model = vosk_model_new([path UTF8String]);
        if (g_model) {
            g_loadedModelLang = [lang copy];
        }
        s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
        DBGLog([NSString stringWithFormat:@"model-%@ loaded %.1fs ok=%d",
            lang, [NSDate timeIntervalSinceReferenceDate] - t0, g_model != nil]);
        s_loading = NO;
    });
}

// ---- RemoteIO Audio Engine ----
static char s_recbuf[16384];
static OSStatus RecCB(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                      const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                      UInt32 inNumberFrames, AudioBufferList *ioData) {
    if (!s_recording) return noErr;
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = 1;
    UInt32 bytes = inNumberFrames * 2;
    if (bytes > sizeof(s_recbuf)) bytes = sizeof(s_recbuf);
    abl.mBuffers[0].mDataByteSize = bytes;
    abl.mBuffers[0].mData = s_recbuf;
    OSStatus r = AudioUnitRender(g_au, ioActionFlags, inTimeStamp, inBusNumber,
                                 inNumberFrames, &abl);
    if (r != noErr) return noErr;
    long w = s_rb_w, rd = s_rb_r;
    long used = w - rd; if (used < 0) used += RB_SIZE;
    long space = RB_SIZE - used;
    if (space < bytes) { g_dropBytes += bytes; return noErr; }
    for (UInt32 i = 0; i < bytes; i++) s_rb[(w + i) % RB_SIZE] = s_recbuf[i];
    s_rb_w = w + bytes;
    g_cbCount++; g_cbBytes += bytes;
    return noErr;
}

static void StartAudio(void) {
    if (g_audioOn) return;
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0; desc.componentFlagsMask = 0;
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { DBGLog(@"no RemoteIO"); return; }
    AudioComponentInstanceNew(comp, &g_au);
    UInt32 one = 1, zero = 0;
    AudioUnitSetProperty(g_au, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Input, 1, &one, sizeof(one));
    AudioUnitSetProperty(g_au, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Output, 0, &zero, sizeof(zero));
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = 16000; fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mBitsPerChannel = 16; fmt.mChannelsPerFrame = 1;
    fmt.mFramesPerPacket = 1; fmt.mBytesPerFrame = 2; fmt.mBytesPerPacket = 2;
    AudioUnitSetProperty(g_au, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
    AURenderCallbackStruct cb;
    cb.inputProc = RecCB; cb.inputProcRefCon = NULL;
    AudioUnitSetProperty(g_au, kAudioOutputUnitProperty_SetInputCallback,
                         kAudioUnitScope_Global, 0, &cb, sizeof(cb));
    AudioSessionInitialize(NULL, NULL, NULL, NULL);
    UInt32 cat = kAudioSessionCategory_PlayAndRecord;
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(cat), &cat);
    AudioSessionSetActive(true);
    AudioUnitInitialize(g_au);
    OSStatus st = AudioOutputUnitStart(g_au);
    if (st != noErr) {
        AudioUnitUninitialize(g_au);
        AudioComponentInstanceDispose(g_au); g_au = NULL;
        usleep(300000);
        AudioComponentInstanceNew(comp, &g_au);
        AudioUnitSetProperty(g_au, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &one, sizeof(one));
        AudioUnitSetProperty(g_au, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &zero, sizeof(zero));
        AudioUnitSetProperty(g_au, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
        AURenderCallbackStruct cb2;
        cb2.inputProc = RecCB; cb2.inputProcRefCon = NULL;
        AudioUnitSetProperty(g_au, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &cb2, sizeof(cb2));
        AudioUnitInitialize(g_au);
        st = AudioOutputUnitStart(g_au);
        DBGLog([NSString stringWithFormat:@"audio retry rc=%d", (int)st]);
    }
    DBGLog([NSString stringWithFormat:@"audio start rc=%d", (int)st]);
    g_audioOn = (st == noErr);
    s_recording = g_audioOn;
}

static void StopAudio(void) {
    s_recording = NO;
    if (g_au) {
        AudioOutputUnitStop(g_au);
        AudioUnitUninitialize(g_au);
        AudioComponentInstanceDispose(g_au);
        g_au = NULL; g_audioOn = NO;
    }
}

// ---- Decoder Worker Thread ----
static void *WorkerFn(void *arg) {
    s_recording = YES;
    s_workerAlive = YES;
    double lastPartialT = 0;
    while (!s_worker_quit) {
        long w = s_rb_w, r = s_rb_r;
        if (w == r) { usleep(20000); continue; }
        static char chunk[16000];
        long avail = w - r; if (avail < 0) avail += RB_SIZE;
        long take = avail > 16000 ? 16000 : avail;
        for (long i = 0; i < take; i++) chunk[i] = s_rb[(r + i) % RB_SIZE];
        s_rb_r = r + take;
        BOOL done = vosk_recognizer_accept_waveform(g_rec, chunk, (int)take) != 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastPartialT > 0.25) {
            lastPartialT = now;
            const char *pr = vosk_recognizer_partial_result(g_rec);
            NSString *pt = JsonText(pr, @"partial") ?: @"";
            if (![pt isEqualToString:g_lastPartial]) {
                int len = g_partialLen;
                g_partialLen = (int)pt.length;
                g_lastPartial = pt;
                dispatch_async(dispatch_get_main_queue(), ^{
                    DeleteBack(len);
                    if (pt.length) InsertText(pt);
                });
            }
        }
        if (done) {
            ClearPartial();
            NSString *seg = JsonText(vosk_recognizer_result(g_rec), @"text");
            if (seg.length) {
                NSString *lang = g_loadedModelLang ?: @"ru";
                NSString *fmt = ApplyPunctuation(seg, lang);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (s_lastWasSpace && ([fmt hasPrefix:@","] || [fmt hasPrefix:@":"] || [fmt hasPrefix:@"—"])) {
                        DeleteBack(1);
                    }
                    InsertText([fmt stringByAppendingString:@" "]);
                    s_lastWasSpace = YES;
                });
            }
        }
    }
    return NULL;
}

static void StartRecordingFull(void) {
    NSString *lang = GetActiveDictationLang();
    EnsureModelLoadedForLang(lang);
    g_cbCount = 0; g_cbBytes = 0; g_dropBytes = 0;
    s_rb_w = s_rb_r = 0; s_worker_quit = NO;
    s_lastWasSpace = NO;
    StartAudio();
    SetState(1); // Audio recording starts immediately
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        if (!g_model || ![g_loadedModelLang isEqualToString:lang]) {
            for (int i = 0; i < 600 && (!g_model || ![g_loadedModelLang isEqualToString:lang]); i++)
                usleep(50000);
            if (!g_model) {
                dispatch_async(dispatch_get_main_queue(), ^{ SetState(0); StopAudio(); });
                return;
            }
        }
        if (s_worker_quit) return;
        g_rec = vosk_recognizer_new(g_model, 16000.0);
        if (pthread_create(&s_worker, NULL, WorkerFn, NULL) != 0)
            s_workerAlive = NO;
        else
            s_workerAlive = YES;
    });
}

static void StopRecordingBg(void) {
    double t0 = [NSDate timeIntervalSinceReferenceDate];
    StopAudio();
    for (int i = 0; i < 600 && !g_model; i++) usleep(50000);
    for (int i = 0; i < 100 && !s_workerAlive && g_model; i++) usleep(20000);
    s_worker_quit = YES;
    if (s_workerAlive) {
        pthread_join(s_worker, NULL);
        s_workerAlive = NO;
    }
    ClearPartial();
    if (g_rec) {
        @try {
            NSString *seg = JsonText(vosk_recognizer_final_result(g_rec), @"text");
            if (seg.length) {
                NSString *lang = g_loadedModelLang ?: @"ru";
                NSString *fmt = ApplyPunctuation(seg, lang);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (s_lastWasSpace && ([fmt hasPrefix:@","] || [fmt hasPrefix:@":"] || [fmt hasPrefix:@"—"])) {
                        DeleteBack(1);
                    }
                    InsertText([fmt stringByAppendingString:@" "]);
                    s_lastWasSpace = YES;
                });
            }
        } @catch (id e) { DBGLog(@"final exc"); }
        vosk_recognizer_free(g_rec); g_rec = NULL;
        DBGLog([NSString stringWithFormat:@"stop %.1fs cb=%ld bytes=%ld drop=%ld",
            [NSDate timeIntervalSinceReferenceDate] - t0, g_cbCount, g_cbBytes, g_dropBytes]);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ SetState(0); });
}

static void AbortOrStopRecording(BOOL isDismiss) {
    if (g_state == 0 && !s_recording) return;
    s_worker_quit = YES;
    StopAudio();
    if (isDismiss) {
        SetState(0);
    } else {
        SetState(2);
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        StopRecordingBg();
    });
}

static void StopRecording(void) {
    AbortOrStopRecording(NO);
}

@interface DKBridge : NSObject
+ (void)tap;
+ (void)scheduleIdleCheck;
+ (void)cancelIdleCheck;
+ (void)idleTimeout;
@end
@implementation DKBridge
+ (void)tap {
    if (!g_btn || g_btn.hidden || g_btn.superview == nil) return;
    if (g_state == 1) { StopRecording(); return; }
    if (g_state != 0) return;
    StartRecordingFull();
}
+ (void)scheduleIdleCheck {
    [self cancelIdleCheck];
    [self performSelector:@selector(idleTimeout) withObject:nil afterDelay:120.0];
}
+ (void)cancelIdleCheck {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(idleTimeout)
                                               object:nil];
}
+ (void)idleTimeout {
    if (g_state == 0 && !s_recording && g_model) {
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (now - s_lastActivityTime >= 115.0) {
            FreeLoadedModel();
            DBGLog(@"idle timeout: freed model after 120s");
        }
    }
}
@end

// ---- Multilingual Settings Localization ----
static NSString *DKLoc(NSString *key) {
    NSString *lang = [[NSLocale preferredLanguages] count] ?
        [[[NSLocale preferredLanguages] objectAtIndex:0] substringToIndex:2] : @"en";

    static NSDictionary *s_dict = nil;
    if (!s_dict) {
        s_dict = [@{
            @"en": @{
                @"MAIN_GRP": @"General",
                @"ENABLED": @"Enabled",
                @"LANG_GRP": @"Keyboard Languages",
                @"LANG_FOOTER": @"Enable installed languages for speech recognition.",
                @"NO_MODELS": @"No models found.\nInstall DictaKey language models from Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Offline Vosk Kaldi ASR for iOS 6\nBaked OpenFST ConstFst graphs and mmap dictionaries."
            },
            @"ru": @{
                @"MAIN_GRP": @"Основное",
                @"ENABLED": @"Включено",
                @"LANG_GRP": @"Языки клавиатуры",
                @"LANG_FOOTER": @"Включите установленные языки для распознавания речи.",
                @"NO_MODELS": @"Модели не найдены.\nУстановите языковые пакеты DictaKey из Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Vosk Kaldi ASR для iOS 6\nЗапеченные графы OpenFST и mmap-словари."
            },
            @"uk": @{
                @"MAIN_GRP": @"Основне",
                @"ENABLED": @"Увімкнено",
                @"LANG_GRP": @"Мови клавіатури",
                @"LANG_FOOTER": @"Увімкніть встановлені мови для розпізнавання мовлення.",
                @"NO_MODELS": @"Моделі не знайдено.\nВстановіть мовні пакети DictaKey з Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Vosk Kaldi ASR для iOS 6\nЗапечені графи OpenFST та mmap-словники."
            },
            @"de": @{
                @"MAIN_GRP": @"Allgemein",
                @"ENABLED": @"Aktiviert",
                @"LANG_GRP": @"Tastatursprachen",
                @"LANG_FOOTER": @"Aktivieren Sie installierte Sprachen für die Spracherkennung.",
                @"NO_MODELS": @"Keine Modelle gefunden.\nInstallieren Sie DictaKey-Sprachmodelle aus Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Offline Vosk Kaldi ASR für iOS 6\nOpenFST ConstFst-Graphen und mmap-Wörterbücher."
            },
            @"fr": @{
                @"MAIN_GRP": @"Général",
                @"ENABLED": @"Activé",
                @"LANG_GRP": @"Langues du clavier",
                @"LANG_FOOTER": @"Activez les langues installées pour la reconnaissance vocale.",
                @"NO_MODELS": @"Aucun modèle trouvé.\nInstallez les modèles DictaKey depuis Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Vosk Kaldi ASR pour iOS 6\nGraphes OpenFST ConstFst et dictionnaires mmap."
            },
            @"es": @{
                @"MAIN_GRP": @"General",
                @"ENABLED": @"Activado",
                @"LANG_GRP": @"Idiomas del teclado",
                @"LANG_FOOTER": @"Active los idiomas instalados para el reconocimiento de voz.",
                @"NO_MODELS": @"No se encontraron modelos.\nInstale modelos DictaKey desde Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Vosk Kaldi ASR para iOS 6\nGrafos OpenFST ConstFst y diccionarios mmap."
            },
            @"it": @{
                @"MAIN_GRP": @"Generale",
                @"ENABLED": @"Abilitato",
                @"LANG_GRP": @"Lingue della tastiera",
                @"LANG_FOOTER": @"Abilita le lingue installate per il riconoscimento vocale.",
                @"NO_MODELS": @"Nessun modello trovato.\nInstalla i modelli DictaKey da Cydia.",
                @"ABOUT": @"DictaKey v1.0 • Vosk Kaldi ASR per iOS 6\nGrafi OpenFST ConstFst e dizionari mmap."
            }
        } retain];
    }

    NSDictionary *lMap = [s_dict objectForKey:lang] ?: [s_dict objectForKey:@"en"];
    return [lMap objectForKey:key] ?: key;
}

// ---- Dynamic PreferenceLoader Integration ----
%group DictaKeyPrefs
%hook PLCustomListController

- (id)specifiers {
    NSMutableArray *specs = %orig;
    PSSpecifier *rootSpec = [self specifier];
    if (![[rootSpec name] isEqualToString:@"DictaKey"]) {
        return specs;
    }

    for (PSSpecifier *s in specs) {
        if ([[s propertyForKey:@"key"] hasPrefix:@"lang_"]) {
            return specs;
        }
    }

    // Localize static specifiers according to user's iOS language
    for (PSSpecifier *s in specs) {
        NSString *sid = [s propertyForKey:@"id"];
        if ([sid isEqualToString:@"DK_MAIN_GROUP"]) {
            [s setName:DKLoc(@"MAIN_GRP")];
        } else if ([sid isEqualToString:@"DK_ENABLED"]) {
            [s setName:DKLoc(@"ENABLED")];
        } else if ([sid isEqualToString:@"DK_LANG_GROUP"]) {
            [s setName:DKLoc(@"LANG_GRP")];
        } else if ([sid isEqualToString:@"DK_ABOUT_GROUP"]) {
            [s setProperty:DKLoc(@"ABOUT") forKey:@"footerText"];
        }
    }

    NSUInteger groupIdx = NSNotFound;
    PSSpecifier *langGroup = nil;
    for (NSUInteger i = 0; i < [specs count]; i++) {
        PSSpecifier *s = [specs objectAtIndex:i];
        if ([[s propertyForKey:@"id"] isEqualToString:@"DK_LANG_GROUP"]) {
            langGroup = s;
            groupIdx = i;
            break;
        }
    }

    if (groupIdx == NSNotFound) return specs;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/vosk" error:NULL];
    NSMutableArray *installedLangs = [NSMutableArray array];
    for (NSString *item in items) {
        if ([item hasPrefix:@"model-"]) {
            NSString *code = [item substringFromIndex:6];
            BOOL isDir = NO;
            NSString *fullPath = [@"/var/mobile/Library/vosk" stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
                if (code.length && ![installedLangs containsObject:code]) {
                    [installedLangs addObject:code];
                }
            }
        }
    }
    [installedLangs sortUsingSelector:@selector(compare:)];

    if ([installedLangs count] == 0) {
        [langGroup setProperty:DKLoc(@"NO_MODELS") forKey:@"footerText"];
    } else {
        [langGroup setProperty:DKLoc(@"LANG_FOOTER") forKey:@"footerText"];

        Class PSTableCellClass = objc_getClass("PSTableCell");
        int switchType = [PSTableCellClass respondsToSelector:@selector(cellTypeFromString:)] ?
            (int)[PSTableCellClass performSelector:@selector(cellTypeFromString:) withObject:@"PSSwitchCell"] : 6;

        NSLocale *curLocale = [NSLocale currentLocale];
        NSUInteger insertIdx = groupIdx + 1;

        for (NSString *lang in installedLangs) {
            NSString *rawName = [curLocale displayNameForKey:NSLocaleLanguageCode value:lang];
            NSString *displayName = rawName.length ?
                [rawName stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                 withString:[[rawName substringToIndex:1] uppercaseString]] :
                [lang uppercaseString];

            PSSpecifier *sw = [objc_getClass("PSSpecifier")
                preferenceSpecifierNamed:displayName
                                  target:self
                                     set:@selector(setPreferenceValue:specifier:)
                                     get:@selector(readPreferenceValue:)
                                  detail:Nil
                                    cell:switchType
                                    edit:Nil];
            [sw setProperty:@"com.local.dictakey" forKey:@"defaults"];
            [sw setProperty:[NSString stringWithFormat:@"lang_%@", lang] forKey:@"key"];
            [sw setProperty:@(YES) forKey:@"default"];
            [sw setProperty:@"com.local.dictakey.settingschanged" forKey:@"PostNotification"];

            [specs insertObject:sw atIndex:insertIdx++];
        }
    }

    return specs;
}

%end
%end

// ---- iOS 6 Skeuomorphic Key Rendering ----
@implementation DKButtonView

- (void)drawRect:(CGRect)r {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextClearRect(c, r);

    // iPad key has padding from slot boundaries and ~4px corner radius
    CGRect keyRect = CGRectMake(1.0, 1.0, r.size.width - 2.0, r.size.height - 3.0);
    CGFloat cornerRadius = 4.0;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:keyRect cornerRadius:cornerRadius];

    // 1. Drop shadow below key (bottom bevel on keyboard texture)
    CGContextSaveGState(c);
    CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.25 alpha:0.6].CGColor);
    CGRect shadowRect = CGRectOffset(keyRect, 0, 1.0);
    UIBezierPath *shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowRect cornerRadius:cornerRadius];
    CGContextAddPath(c, shadowPath.CGPath);
    CGContextFillPath(c);
    CGContextRestoreGState(c);

    // 2. Key background gradient
    CGContextSaveGState(c);
    CGContextAddPath(c, path.CGPath);
    CGContextClip(c);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat topR, topG, topB, botR, botG, botB;

    if (g_state == 1) {
        // Recording: vibrant iOS 6 red gradient
        topR = 0.92; topG = 0.22; topB = 0.22;
        botR = 0.68; botG = 0.08; botB = 0.08;
    } else if (g_state == 2) {
        // Finalizing: warm gold gradient
        topR = 0.96; topG = 0.76; topB = 0.16;
        botR = 0.80; botG = 0.58; botB = 0.05;
    } else {
        // Idle: native gray gradient matching iPad iOS 6 functional keys (.?123 / Shift)
        topR = 0.83; topG = 0.85; topB = 0.88;
        botR = 0.69; botG = 0.72; botB = 0.76;
    }

    CGFloat colors[] = {
        topR, topG, topB, 1.0,
        botR, botG, botB, 1.0
    };
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, colors, NULL, 2);
    CGContextDrawLinearGradient(c, grad, CGPointMake(0, keyRect.origin.y),
                               CGPointMake(0, CGRectGetMaxY(keyRect)), 0);
    CGGradientRelease(grad);

    // 3. Inner top specular highlight (1px translucent white)
    UIBezierPath *highlightPath = [UIBezierPath bezierPathWithRoundedRect:
        CGRectInset(keyRect, 0.5, 0.5) cornerRadius:cornerRadius - 0.5];
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithWhite:1.0 alpha:(g_state == 1 ? 0.35 : 0.60)].CGColor);
    CGContextSetLineWidth(c, 1.0);
    CGContextAddPath(c, highlightPath.CGPath);
    CGContextStrokePath(c);

    CGContextRestoreGState(c);

    // 4. Subtle outer contour stroke
    CGContextSaveGState(c);
    UIColor *borderColor = (g_state == 1) ? [UIColor colorWithRed:0.50 green:0.05 blue:0.05 alpha:1.0]
                         : (g_state == 2) ? [UIColor colorWithRed:0.60 green:0.42 blue:0.02 alpha:1.0]
                         : [UIColor colorWithRed:0.52 green:0.54 blue:0.58 alpha:1.0];
    CGContextSetStrokeColorWithColor(c, borderColor.CGColor);
    CGContextSetLineWidth(c, 1.0);
    CGContextAddPath(c, path.CGPath);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);

    // 5. Microphone icon (centered inside the key)
    CGFloat s = MIN(keyRect.size.width, keyRect.size.height);
    CGFloat cx = CGRectGetMidX(keyRect);
    CGFloat cy = CGRectGetMidY(keyRect);

    CGContextSaveGState(c);
    if (g_state == 1) {
        CGContextSetShadowWithColor(c, CGSizeMake(0, -1), 0, [UIColor colorWithRed:0.4 green:0.0 blue:0.0 alpha:0.8].CGColor);
        CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
        CGContextSetStrokeColorWithColor(c, [UIColor whiteColor].CGColor);
    } else {
        CGContextSetShadowWithColor(c, CGSizeMake(0, 1), 0, [UIColor colorWithWhite:1.0 alpha:0.7].CGColor);
        UIColor *ink = [UIColor colorWithRed:0.25 green:0.27 blue:0.30 alpha:1.0];
        CGContextSetFillColorWithColor(c, ink.CGColor);
        CGContextSetStrokeColorWithColor(c, ink.CGColor);
    }

    // Microphone capsule
    CGFloat cw = s * 0.22, ch = s * 0.38;
    UIBezierPath *cap = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(cx - cw / 2.0, cy - s * 0.28, cw, ch)
        cornerRadius:cw / 2.0];
    CGContextAddPath(c, cap.CGPath);
    CGContextFillPath(c);

    // Cradle arc
    CGFloat lw = s * 0.040, rr = s * 0.22;
    CGContextSetLineWidth(c, lw);
    CGContextSetLineCap(c, kCGLineCapRound);
    UIBezierPath *arc = [UIBezierPath bezierPath];
    [arc addArcWithCenter:CGPointMake(cx, cy - s * 0.08) radius:rr
        startAngle:-0.05 * M_PI endAngle:1.05 * M_PI clockwise:YES];
    CGContextAddPath(c, arc.CGPath);
    CGContextStrokePath(c);

    // Stand base
    CGContextFillRect(c, CGRectMake(cx - lw / 2.0, cy - s * 0.08 + rr, lw, s * 0.12));
    CGContextFillRect(c, CGRectMake(cx - s * 0.13, cy - s * 0.08 + rr + s * 0.12, s * 0.26, lw));

    // 6. Language badge ("RU", "EN", etc.) in the bottom right corner
    if (self.langCode.length > 0) {
        CGFloat badgeH = s * 0.20;
        CGFloat badgeW = s * 0.40;
        UIFont *font = [UIFont boldSystemFontOfSize:s * 0.18];
        CGRect badgeRect = CGRectMake(CGRectGetMaxX(keyRect) - badgeW - 3.0,
                                      CGRectGetMaxY(keyRect) - badgeH - 3.0,
                                      badgeW, badgeH);
        [self.langCode drawInRect:badgeRect withFont:font
                    lineBreakMode:NSLineBreakByClipping
                        alignment:NSTextAlignmentRight];
    }

    CGColorSpaceRelease(cs);
    CGContextRestoreGState(c);
}

- (void)dealloc {
    [_langCode release];
    [super dealloc];
}

@end

static CGRect RectFor(UIView *kb) {
    CGFloat kw = kb.bounds.size.width, kh = kb.bounds.size.height;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        if (kw > 800.0)
            return CGRectMake(819 * kw / 1024.0, 267 * kh / 352.0,
                              110 * kw / 1024.0, 79 * kh / 352.0 - 2);
        return CGRectMake(615 * kw / 768.0, 200 * kh / 264.0,
                          82 * kw / 768.0, 60 * kh / 264.0 - 2);
    }
    // iPhone / iPod touch: place immediately to the left of the space bar
    if (kw > 350.0) { // landscape (480x162 on iPhone 4)
        // Globe is (50 125; 44 36), Space starts at x=98
        return CGRectMake(98.0, 125.0, 44.0, 34.0);
    }
    // portrait (320x216 on iPhone 4)
    // Globe is at 42..76, Space starts at x=80, top=173, height=40 (key body 37, matches Space/Globe)
    return CGRectMake(80.0, 173.0, 34.0, 40.0);
}

static void Reposition(void) {
    Class kbcls = objc_getClass("UIKeyboardImpl");
    UIKeyboardImpl *kb = [kbcls performSelector:@selector(sharedInstance)];
    if (!kb || kb.bounds.size.width < 100) return;

    ReloadSettings();
    NSString *lang = GetActiveDictationLang();
    BOOL allowed = IsLangAllowed(lang);
    NSString *modelPath = ModelPathForLang(lang);

    if (!allowed || !modelPath) {
        if (g_btn) g_btn.hidden = YES;
        return;
    }

    [DKBridge cancelIdleCheck];
    s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];

    if (g_btn && g_owner != kb) { [g_btn removeFromSuperview]; g_btn = nil; }
    if (!g_btn) {
        DKButtonView *bv = [[DKButtonView alloc] initWithFrame:CGRectZero];
        bv.backgroundColor = [UIColor clearColor];
        bv.opaque = NO;
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc]
            initWithTarget:[DKBridge class] action:@selector(tap)];
        [bv addGestureRecognizer:t];
        [t release];
        g_btn = bv;
        g_owner = kb;
    }

    DKButtonView *bv = (DKButtonView *)g_btn;
    bv.langCode = [lang uppercaseString];

    if (g_btn.superview != kb) [kb addSubview:g_btn];
    g_btn.frame = RectFor(kb);
    g_btn.hidden = NO;
    [kb bringSubviewToFront:g_btn];

    if (g_state != 1) {
        SetState(0);
    } else {
        SetState(1);
    }
}

static void (*orig_DismissKeyboard)(id, SEL);
static void New_DismissKeyboard(id self, SEL _cmd) {
    AbortOrStopRecording(YES);
    s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
    [DKBridge scheduleIdleCheck];
    if (orig_DismissKeyboard) orig_DismissKeyboard(self, _cmd);
}

static void (*orig_HideKeyboard)(id, SEL);
static void New_HideKeyboard(id self, SEL _cmd) {
    AbortOrStopRecording(YES);
    s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
    [DKBridge scheduleIdleCheck];
    if (orig_HideKeyboard) orig_HideKeyboard(self, _cmd);
}

static void SettingsChangedCB(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo) {
    ReloadSettings();
    dispatch_async(dispatch_get_main_queue(), ^{
        Reposition();
    });
}

__attribute__((constructor)) static void DKInit(void) {
    Class implCls = objc_getClass("UIKeyboardImpl");
    if (implCls) {
        MSHookMessageEx(implCls, @selector(layoutSubviews),
            (IMP)New_ImpLayout, (IMP *)&orig_ImpLayout);
        MSHookMessageEx(implCls, @selector(dismissKeyboard),
            (IMP)New_DismissKeyboard, (IMP *)&orig_DismissKeyboard);
        MSHookMessageEx(implCls, @selector(hideKeyboard),
            (IMP)New_HideKeyboard, (IMP *)&orig_HideKeyboard);
    }
    Class lsCls = objc_getClass("UIKeyboardLayoutStar");
    if (lsCls) MSHookMessageEx(lsCls, @selector(layoutSubviews),
        (IMP)New_LSLayout, (IMP *)&orig_LSLayout);

    Class imcCls = objc_getClass("UIKeyboardInputModeController");
    if (imcCls) {
        MSHookMessageEx(imcCls, @selector(setCurrentInputMode:),
            (IMP)New_SetCurrentInputMode, (IMP *)&orig_SetCurrentInputMode);
    }

    void (^stopAndScheduleIdle)(NSNotification *) = ^(NSNotification *n) {
        AbortOrStopRecording(YES);
        s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
        [DKBridge scheduleIdleCheck];
    };
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIKeyboardWillHideNotification" object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:stopAndScheduleIdle];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIKeyboardDidHideNotification" object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:stopAndScheduleIdle];

    void (^stopAndCancelTimer)(NSNotification *) = ^(NSNotification *n) {
        AbortOrStopRecording(YES);
        s_lastActivityTime = [NSDate timeIntervalSinceReferenceDate];
        [DKBridge cancelIdleCheck];
    };
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationWillResignActiveNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:stopAndCancelTimer];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:stopAndCancelTimer];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            double now = [NSDate timeIntervalSinceReferenceDate];
            if (g_state == 0 && !s_recording && g_model && s_lastActivityTime > 0) {
                if (now - s_lastActivityTime >= 120.0) {
                    FreeLoadedModel();
                    DBGLog(@"app resume: freed model after >120s inactivity");
                }
            }
            [DKBridge cancelIdleCheck];
            s_lastActivityTime = now;
        }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            if (g_state == 0 && !s_recording) {
                [DKBridge cancelIdleCheck];
                FreeLoadedModel();
                DBGLog(@"memory warning: freed model immediately");
            }
        }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UITextInputCurrentInputModeDidChangeNotification" object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            AbortOrStopRecording(YES);
            Reposition();
        }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIKeyboardDidShowNotification" object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                ^{ Reposition(); });
        }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                ^{ Reposition(); });
        }];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, SettingsChangedCB,
                                    CFSTR("com.local.dictakey.settingschanged"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) {
        dlopen("/usr/lib/libprefs.dylib", RTLD_LAZY);
        Class plc = objc_getClass("PLCustomListController");
        if (plc) {
            %init(DictaKeyPrefs, PLCustomListController = plc);
        }
    }

    [@"loaded" writeToFile:@"/var/mobile/Library/dictakey.loaded"
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
