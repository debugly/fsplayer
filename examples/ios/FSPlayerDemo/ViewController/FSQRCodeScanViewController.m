/*
 * Copyright (C) 2015 Gdier
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FSQRCodeScanViewController.h"
#import "FSMoviePlayerViewController.h"
#import "Barcode.h"
#import <AVFoundation/AVFoundation.h>

@interface FSQRCodeScanViewController () <AVCaptureMetadataOutputObjectsDelegate>

@property (weak, nonatomic) IBOutlet UIView *previewView;
@property (strong, nonatomic) NSMutableArray * allowedBarcodeTypes;

//@property (strong, nonatomic) SettingsViewController * settingsVC;

@end

@implementation FSQRCodeScanViewController {

    AVCaptureSession *_captureSession;
    AVCaptureDevice *_videoDevice;
    AVCaptureDeviceInput *_videoInput;
    AVCaptureVideoPreviewLayer *_previewLayer;
    BOOL _running;
    BOOL _showingBarcodeAlert;
    AVCaptureMetadataOutput *_metadataOutput;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"Scan QRCode";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self setupCaptureSession];
    _previewLayer.frame = _previewView.bounds;
    [_previewView.layer addSublayer:_previewLayer];
    
    // listen for going into the background and stop the session
    
    // set default allowed barcode types, remove types via setings menu if you don't want them to be able to be scanned
    self.allowedBarcodeTypes = [NSMutableArray new];
    [self.allowedBarcodeTypes addObject:@"org.iso.QRCode"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    _previewLayer.frame = _previewView.bounds;
    
    [self setupCaptureOrientation];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startRunning];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _previewLayer.frame = _previewView.bounds;
    [self setupCaptureOrientation];
}


- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopRunning];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - AV capture methods

- (void)setupCaptureSession {

    if (_captureSession) {
        return;
    }

    _videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!_videoDevice) {
        return;
    }

    _captureSession = [[AVCaptureSession alloc] init];
    _videoInput = [[AVCaptureDeviceInput alloc] initWithDevice:_videoDevice error:nil];

    if ([_captureSession canAddInput:_videoInput]) {
        [_captureSession addInput:_videoInput];
    }
    _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:_captureSession];
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    // capture and process the metadata
    _metadataOutput = [[AVCaptureMetadataOutput alloc] init];

    [_metadataOutput setMetadataObjectsDelegate:self
                                          queue:dispatch_get_main_queue()];
    
    if ([_captureSession canAddOutput:_metadataOutput]) {
        [_captureSession addOutput:_metadataOutput];
    }
}

- (void)setupCaptureOrientation {
    if ([_previewLayer.connection isVideoOrientationSupported]) {
        UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
        } else {
            interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
        }
        AVCaptureVideoOrientation orientation;

        switch (interfaceOrientation) {
            case UIInterfaceOrientationLandscapeLeft:
                orientation = AVCaptureVideoOrientationLandscapeLeft;
                break;
                
            case UIInterfaceOrientationLandscapeRight:
                orientation = AVCaptureVideoOrientationLandscapeRight;
                break;

            case UIInterfaceOrientationPortraitUpsideDown:
                orientation = AVCaptureVideoOrientationPortraitUpsideDown;
                break;

            default:
                // A portrait scanner must not use the landscape sensor orientation.
                orientation = AVCaptureVideoOrientationPortrait;
                break;
        }
        
        [_previewLayer.connection setVideoOrientation:orientation];
    }
}

- (void)startRunning {
    if (_running || _showingBarcodeAlert) return;
    [_captureSession startRunning];
    _metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];//_metadataOutput.availableMetadataObjectTypes;

    _running = YES;
}

- (void)stopRunning {
    if (!_running) return;
    [_captureSession stopRunning];
    _running = NO;
}

- (void)applicationWillEnterForeground:(NSNotification*)note {
    [self startRunning];
}
- (void)applicationDidEnterBackground:(NSNotification*)note {
    [self stopRunning];
}

#pragma mark - Delegate functions

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection {
    
    [metadataObjects enumerateObjectsUsingBlock:^(AVMetadataObject *obj, NSUInteger idx, BOOL *stop) {
         if ([obj isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {

             AVMetadataMachineReadableCodeObject *code = (AVMetadataMachineReadableCodeObject *) [_previewLayer transformedMetadataObjectForMetadataObject:obj];

             Barcode * barcode = [Barcode processMetadataObject:code];
             
             for(NSString * str in self.allowedBarcodeTypes) {
                 if([barcode.getBarcodeType isEqualToString:str]) {
                     [self validBarcodeFound:barcode];
                     *stop = YES;
                     return;
                 }
             }
         }
     }];
}

- (void)validBarcodeFound:(Barcode *)barcode {
    // Capture callbacks already queued before stopRunning may still arrive.
    if (_showingBarcodeAlert || self.presentedViewController || !self.view.window) {
        return;
    }
    _showingBarcodeAlert = YES;
    [self stopRunning];
    [self showBarcodeAlert:barcode];
}

- (void)showBarcodeAlert:(Barcode *)barcode {
    NSString *url = [barcode.getBarcodeData copy];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                 message:url
                                                          preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Scan Again"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_showingBarcodeAlert = NO;
        [self startRunning];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Play"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // Finish dismissing the alert before presenting the video controller.
        [self dismissViewControllerAnimated:YES completion:^{
            [FSVideoViewController presentFromViewController:self
                                                  withTitle:[NSString stringWithFormat:@"URL: %@", url]
                                                        URL:url completion:^{
                [self.navigationController popViewControllerAnimated:NO];
            }];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
