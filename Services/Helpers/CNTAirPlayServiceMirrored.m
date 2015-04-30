//
//  CNTAirPlayServiceMirrored.m
//  Connect SDK
//
//  Created by Jeremy White on 5/28/14.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "CNTAirPlayServiceMirrored.h"
#import <AVFoundation/AVPlayerItem.h>
#import <AVFoundation/AVAsset.h>
#import "CNTConnectError.h"
#import "CNTAirPlayWebAppSession.h"
#import "CNTConnectUtil.h"
#import "CNTAirPlayService.h"


@interface CNTAirPlayServiceMirrored () <CNTServiceCommandDelegate, UIWebViewDelegate, UIAlertViewDelegate>

@property (nonatomic, copy) CNTSuccessBlock launchSuccessBlock;
@property (nonatomic, copy) CNTFailureBlock launchFailureBlock;

@property (nonatomic) CNTAirPlayWebAppSession *activeWebAppSession;
@property (nonatomic) CNTServiceSubscription *playStateSubscription;

@end

@implementation CNTAirPlayServiceMirrored
{
    NSTimer *_connectTimer;
    UIAlertView *_connectingAlertView;
}

- (instancetype) initWithAirPlayService:(CNTAirPlayService *)service
{
    self = [super init];

    if (self)
    {
        _service = service;
    }

    return self;
}

- (void) sendNotSupportedFailure:(CNTFailureBlock)failure
{
    if (failure)
        failure([CNTConnectError generateErrorWithCode:CNTConnectStatusCodeNotSupported andDetails:nil]);
}

- (void) connect
{
    [self checkForExistingScreenAndInitializeIfPresent];

    if (self.secondWindow && self.secondWindow.screen)
    {
        _connecting = NO;
        _connected = YES;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hScreenDisconnected:) name:UIScreenDidDisconnectNotification object:nil];

        if (self.service.connected && self.service.delegate && [self.service.delegate respondsToSelector:@selector(deviceServiceConnectionSuccess:)])
            dispatch_on_main(^{ [self.service.delegate deviceServiceConnectionSuccess:self.service]; });
    } else
    {
        _connected = NO;
        _connecting = YES;

        [self checkScreenCount];

        NSString *title = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_AirPlay_Mirror_Title" value:@"Mirroring Required" table:@"ConnectSDK"];
        NSString *message = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_AirPlay_Mirror_Description" value:@"Enable AirPlay mirroring to connect to this device" table:@"ConnectSDK"];
        NSString *ok = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_AirPlay_Mirror_OK" value:@"OK" table:@"ConnectSDK"];
        NSString *cancel = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_AirPlay_Mirror_Cancel" value:@"Cancel" table:@"ConnectSDK"];

        _connectingAlertView = [[UIAlertView alloc] initWithTitle:title message:message delegate:self cancelButtonTitle:cancel otherButtonTitles:ok, nil];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hScreenConnected:) name:UIScreenDidConnectNotification object:nil];

        if (self.service && self.service.delegate && [self.service.delegate respondsToSelector:@selector(deviceService:pairingRequiredOfType:withData:)])
            dispatch_on_main(^{ [self.service.delegate deviceService:self.service pairingRequiredOfType:CNTDeviceServicePairingTypeAirPlayMirroring withData:_connectingAlertView]; });
    }
}

- (void) disconnect
{
    _connected = NO;
    _connecting = NO;

    [NSObject cancelPreviousPerformRequestsWithTarget:self];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIScreenDidConnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIScreenDidDisconnectNotification object:nil];

    if (self.secondWindow)
    {
        _secondWindow.hidden = YES;
        _secondWindow.screen = nil;
        _secondWindow = nil;
    }

    if (_connectTimer)
    {
        [_connectTimer invalidate];
        _connectTimer = nil;
    }

    if (_connectingAlertView)
        dispatch_on_main(^{ [_connectingAlertView dismissWithClickedButtonIndex:0 animated:NO]; });

    if (self.service && self.service.delegate && [self.service.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)])
        [self.service.delegate deviceService:self.service disconnectedWithError:nil];
}

- (void) alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    _connectingAlertView.delegate = nil;
    _connectingAlertView = nil;

    if (buttonIndex == 0 && _connecting)
        [self disconnect];
}

- (int) sendSubscription:(CNTServiceSubscription *)subscription type:(CNTServiceSubscriptionType)type payload:(id)payload toURL:(NSURL *)URL withId:(int)callId
{
    if (type == CNTServiceSubscriptionTypeUnsubscribe)
    {
        if (subscription == self.playStateSubscription)
        {
            [[self.playStateSubscription successCalls] removeAllObjects];
            [[self.playStateSubscription failureCalls] removeAllObjects];
            [self.playStateSubscription setIsSubscribed:NO];
            self.playStateSubscription = nil;
        }
    }

    return -1;
}

#pragma mark - External display detection, setup

- (void) checkScreenCount
{
    if (_connectTimer)
    {
        [_connectTimer invalidate];
        _connectTimer = nil;
    }

    if (!self.connecting)
        return;

    if ([UIScreen screens].count > 1)
    {
        _connecting = NO;
        _connected = YES;

        if (_connectingAlertView)
            dispatch_on_main(^{ [_connectingAlertView dismissWithClickedButtonIndex:1 animated:NO]; });

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(hScreenDisconnected:) name:UIScreenDidDisconnectNotification object:nil];

        if (self.service.connected && self.service.delegate && [self.service.delegate respondsToSelector:@selector(deviceServiceConnectionSuccess:)])
            dispatch_on_main(^{ [self.service.delegate deviceServiceConnectionSuccess:self.service]; });
    } else
    {
        _connectTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(checkScreenCount) userInfo:nil repeats:NO];
    }
}

- (void)checkForExistingScreenAndInitializeIfPresent
{
    if ([[UIScreen screens] count] > 1)
    {
        UIScreen *secondScreen = [[UIScreen screens] objectAtIndex:1];

        CGRect screenBounds = secondScreen.bounds;

        _secondWindow = [[UIWindow alloc] initWithFrame:screenBounds];
        _secondWindow.screen = secondScreen;
        [_secondWindow makeKeyAndVisible];

        DLog(@"Displaying content with bounds %@", NSStringFromCGRect(screenBounds));
    }
}

- (void) hScreenConnected:(NSNotification *)notification
{
    DLog(@"%@", notification);

    if (!self.secondWindow)
        [self checkForExistingScreenAndInitializeIfPresent];

    [self checkScreenCount];
}

- (void) hScreenDisconnected:(NSNotification *)notification
{
    DLog(@"%@", notification);

    if (_connecting || _connected)
        [self disconnect];
}

#pragma mark - CNTWebAppLauncher

- (id <CNTWebAppLauncher>) webAppLauncher
{
    return self;
}

- (CNTCapabilityPriorityLevel) webAppLauncherPriority
{
    return CNTCapabilityPriorityLevelHigh;
}

- (void) launchWebApp:(NSString *)webAppId success:(CNTWebAppLaunchSuccessBlock)success failure:(CNTFailureBlock)failure
{
    [self launchWebApp:webAppId params:nil relaunchIfRunning:YES success:success failure:failure];
}

- (void) launchWebApp:(NSString *)webAppId params:(NSDictionary *)params success:(CNTWebAppLaunchSuccessBlock)success failure:(CNTFailureBlock)failure
{
    [self launchWebApp:webAppId params:params relaunchIfRunning:YES success:success failure:failure];
}

- (void) launchWebApp:(NSString *)webAppId params:(NSDictionary *)params relaunchIfRunning:(BOOL)relaunchIfRunning success:(CNTWebAppLaunchSuccessBlock)success failure:(CNTFailureBlock)failure
{
    if (!webAppId || webAppId.length == 0)
    {
        if (failure)
            failure([CNTConnectError generateErrorWithCode:CNTConnectStatusCodeArgumentError andDetails:@"You must provide a valid web app URL"]);

        return;
    }

    [self checkForExistingScreenAndInitializeIfPresent];

    if (!self.secondWindow || !self.secondWindow.screen)
    {
        if (failure)
            failure([CNTConnectError generateErrorWithCode:CNTConnectStatusCodeError andDetails:@"Could not detect a second screen -- make sure you have mirroring enabled"]);

        return;
    }

    if (_webAppWebView)
    {
        if (relaunchIfRunning)
        {
            [self closeWebApp:nil success:^(id responseObject)
                    {
                        [self launchWebApp:webAppId params:params relaunchIfRunning:relaunchIfRunning success:success failure:failure];
                    } failure:failure];

            return;
        } else
        {
            NSString *webAppHost = _webAppWebView.request.URL.host;

            if ([webAppId rangeOfString:webAppHost].location != NSNotFound)
            {
                if (params && params.count > 0)
                {
                    [self.activeWebAppSession connectWithSuccess:^(id connectResponseObject)
                            {
                                [self.activeWebAppSession sendJSON:params success:^(id sendResponseObject)
                                        {
                                            if (success)
                                                success(self.activeWebAppSession);
                                        } failure:failure];
                            } failure:failure];
                } else
                {
                    if (success)
                        dispatch_on_main(^{ success(self.activeWebAppSession); });
                }

                return;
            }
        }
    }

    DLog(@"Created a web view with bounds %@", NSStringFromCGRect(self.secondWindow.bounds));

    _webAppWebView = [[UIWebView alloc] initWithFrame:self.secondWindow.bounds];
    _webAppWebView.allowsInlineMediaPlayback = YES;
    _webAppWebView.mediaPlaybackAllowsAirPlay = NO;
    _webAppWebView.mediaPlaybackRequiresUserAction = NO;

    UIViewController *secondScreenViewController = [[UIViewController alloc] init];
    secondScreenViewController.view = _webAppWebView;
    _webAppWebView.delegate = self;
    self.secondWindow.rootViewController = secondScreenViewController;
    self.secondWindow.hidden = NO;

    CNTLaunchSession *launchSession = [CNTLaunchSession launchSessionForAppId:webAppId];
    launchSession.sessionType = CNTLaunchSessionTypeWebApp;
    launchSession.service = self.service;

    CNTAirPlayWebAppSession *webAppSession = [[CNTAirPlayWebAppSession alloc] initWithLaunchSession:launchSession service:self.service];
    self.activeWebAppSession = webAppSession;

    __weak CNTAirPlayWebAppSession *weakSession = self.activeWebAppSession;

    if (params && params.count > 0)
    {
        self.launchSuccessBlock = ^(id launchResponseObject)
        {
            [weakSession connectWithSuccess:^(id connectResponseObject)
                    {
                        [weakSession sendJSON:params success:^(id sendResponseObject)
                                {
                                    if (success)
                                        success(weakSession);
                                } failure:failure];
                    } failure:failure];
        };
    } else
    {
        self.launchSuccessBlock = ^(id responseObject)
        {
            if (success)
                success(weakSession);
        };
    }

    self.launchFailureBlock = failure;

    NSURL *URL = [NSURL URLWithString:webAppId];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];

    [self.webAppWebView loadRequest:request];
}

- (void) launchWebApp:(NSString *)webAppId relaunchIfRunning:(BOOL)relaunchIfRunning success:(CNTWebAppLaunchSuccessBlock)success failure:(CNTFailureBlock)failure
{
    [self launchWebApp:webAppId params:nil relaunchIfRunning:YES success:success failure:failure];
}

- (void) joinWebApp:(CNTLaunchSession *)webAppLaunchSession success:(CNTWebAppLaunchSuccessBlock)success failure:(CNTFailureBlock)failure
{
    if (self.webAppWebView && self.connected)
    {
        NSString *webAppHost = self.webAppWebView.request.URL.host;

        if ([webAppLaunchSession.appId rangeOfString:webAppHost].location != NSNotFound)
        {
            CNTAirPlayWebAppSession *webAppSession = [[CNTAirPlayWebAppSession alloc] initWithLaunchSession:webAppLaunchSession service:self.service];
            self.activeWebAppSession = webAppSession;

            [webAppSession connectWithSuccess:success failure:failure];
        } else
        {
            if (failure)
                dispatch_on_main(^{ failure([CNTConnectError generateErrorWithCode:CNTConnectStatusCodeError andDetails:@"Web is not currently running"]); });
        }
    } else
    {
        if (failure)
            dispatch_on_main(^{ failure([CNTConnectError generateErrorWithCode:CNTConnectStatusCodeError andDetails:@"Web is not currently running"]); });
    }
}

- (void) joinWebAppWithId:(NSString *)webAppId success:(CNTWebAppLaunchSuccessBlock)success failure:(CNTFailureBlock)failure
{
    CNTLaunchSession *launchSession = [CNTLaunchSession launchSessionForAppId:webAppId];
    launchSession.service = self.service;
    launchSession.sessionType = CNTLaunchSessionTypeWebApp;

    [self joinWebApp:launchSession success:success failure:failure];
}

- (void) disconnectFromWebApp
{
    if (self.activeWebAppSession)
    {
        if (self.activeWebAppSession.delegate && [self.activeWebAppSession.delegate respondsToSelector:@selector(webAppSessionDidDisconnect:)])
            dispatch_on_main(^{ [self.activeWebAppSession.delegate webAppSessionDidDisconnect:self.activeWebAppSession]; });

        self.activeWebAppSession = nil;
    }

    self.launchSuccessBlock = nil;
    self.launchFailureBlock = nil;
}

- (void) closeWebApp:(CNTLaunchSession *)launchSession success:(CNTSuccessBlock)success failure:(CNTFailureBlock)failure
{
    [self disconnectFromWebApp];

    if (_secondWindow)
    {
        _secondWindow.rootViewController = nil;
        _secondWindow.hidden = YES;
        _secondWindow.screen = nil;
        _secondWindow = nil;

        _webAppWebView.delegate = nil;
        _webAppWebView = nil;
    }

    if (success)
        success(nil);
}

- (void) pinWebApp:(NSString *)webAppId success:(CNTSuccessBlock)success failure:(CNTFailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

-(void)unPinWebApp:(NSString *)webAppId success:(CNTSuccessBlock)success failure:(CNTFailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)isWebAppPinned:(NSString *)webAppId success:(CNTWebAppPinStatusBlock)success failure:(CNTFailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (CNTServiceSubscription *)subscribeIsWebAppPinned:(NSString*)webAppId success:(CNTWebAppPinStatusBlock)success failure:(CNTFailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
    return nil;
}


#pragma mark - UIWebViewDelegate

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error
{
    DLog(@"%@", error.localizedDescription);

    if (self.launchFailureBlock)
        self.launchFailureBlock(error);

    self.launchSuccessBlock = nil;
    self.launchFailureBlock = nil;
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    if ([request.URL.absoluteString hasPrefix:@"connectsdk://"])
    {
        NSString *jsonString = [[request.URL.absoluteString componentsSeparatedByString:@"connectsdk://"] lastObject];
        jsonString = [CNTConnectUtil urlDecode:jsonString];

        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];

        NSError *jsonError;
        id messageObject = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];

        if (jsonError || !messageObject)
            messageObject = jsonString;

        DLog(@"Got p2p message from web app:\n%@", messageObject);

        if (self.activeWebAppSession)
        {
            NSString *webAppHost = self.webAppWebView.request.URL.host;

            // check if current running web app matches the current web app session
            if ([self.activeWebAppSession.launchSession.appId rangeOfString:webAppHost].location != NSNotFound)
            {
                dispatch_on_main(^{
                    if (self.activeWebAppSession)
                        self.activeWebAppSession.messageHandler(messageObject);
                });
            } else
                [self.activeWebAppSession disconnectFromWebApp];
        }

        return NO;
    } else
    {
        return YES;
    }
}

- (void)webViewDidFinishLoad:(UIWebView *)webView
{
    DLog(@"%@", webView.request.URL.absoluteString);

    if (self.launchSuccessBlock)
        self.launchSuccessBlock(nil);

    self.launchSuccessBlock = nil;
    self.launchFailureBlock = nil;
}

- (void)webViewDidStartLoad:(UIWebView *)webView
{
    DLog(@"%@", webView.request.URL.absoluteString);
}

@end