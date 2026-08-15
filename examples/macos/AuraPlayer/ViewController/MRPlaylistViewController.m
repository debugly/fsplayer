//
//  MRPlaylistViewController.m
//  AuraPlayer
//
//  Created by debugly on 2024/1/24.
//  Copyright © 2024 FSPlayer Mac. All rights reserved.
//

#import "MRPlaylistViewController.h"
#import "MRHoverTextButton.h"

#pragma mark - MRPlaylistCellView

@interface MRPlaylistCellView : NSTableCellView

@property (nonatomic, strong) NSTextField *indexLb;
@property (nonatomic, strong) NSTextField *playIconLb;
@property (nonatomic, strong) NSTextField *titleLb;
@property (nonatomic, strong) MRHoverTextButton *deleteBtn;
@property (nonatomic, copy) void (^onDeleteBlock)(void);

@end

@implementation MRPlaylistCellView

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        
        _indexLb = [[NSTextField alloc] init];
        _indexLb.translatesAutoresizingMaskIntoConstraints = NO;
        _indexLb.bezeled = NO;
        _indexLb.drawsBackground = NO;
        _indexLb.editable = NO;
        _indexLb.selectable = NO;
        _indexLb.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        _indexLb.textColor = [NSColor secondaryLabelColor];
        _indexLb.alignment = NSTextAlignmentRight;
        _indexLb.usesSingleLineMode = YES;
        [self addSubview:_indexLb];
        
        _playIconLb = [[NSTextField alloc] init];
        _playIconLb.translatesAutoresizingMaskIntoConstraints = NO;
        _playIconLb.bezeled = NO;
        _playIconLb.drawsBackground = NO;
        _playIconLb.editable = NO;
        _playIconLb.selectable = NO;
        _playIconLb.stringValue = @"▶";
        _playIconLb.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
        _playIconLb.textColor = [NSColor colorWithRed:0.25 green:0.85 blue:0.45 alpha:1.0];
        _playIconLb.alignment = NSTextAlignmentCenter;
        [self addSubview:_playIconLb];
        
        _titleLb = [[NSTextField alloc] init];
        _titleLb.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLb.bezeled = NO;
        _titleLb.drawsBackground = NO;
        _titleLb.editable = NO;
        _titleLb.selectable = NO;
        _titleLb.usesSingleLineMode = YES;
        _titleLb.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _titleLb.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
        _titleLb.textColor = [NSColor whiteColor];
        [self addSubview:_titleLb];
        
        _deleteBtn = [[MRHoverTextButton alloc] init];
        _deleteBtn.normalColor = [NSColor colorWithWhite:0.6 alpha:1.0];
        _deleteBtn.hoverColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
        _deleteBtn.title = @"✕";
        _deleteBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        _deleteBtn.target = self;
        _deleteBtn.action = @selector(onDeletePressed:);
        [self addSubview:_deleteBtn];
        
        [NSLayoutConstraint activateConstraints:@[
            [_indexLb.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_indexLb.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_indexLb.widthAnchor constraintEqualToConstant:30],
            
            [_playIconLb.leadingAnchor constraintEqualToAnchor:_indexLb.trailingAnchor constant:2],
            [_playIconLb.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_playIconLb.widthAnchor constraintEqualToConstant:14],
            
            [_titleLb.leadingAnchor constraintEqualToAnchor:_playIconLb.trailingAnchor constant:4],
            [_titleLb.trailingAnchor constraintEqualToAnchor:_deleteBtn.leadingAnchor constant:-6],
            [_titleLb.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            
            [_deleteBtn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_deleteBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_deleteBtn.widthAnchor constraintEqualToConstant:20],
            [_deleteBtn.heightAnchor constraintEqualToConstant:20]
        ]];
    }
    return self;
}

- (void)onDeletePressed:(id)sender
{
    if (self.onDeleteBlock) {
        self.onDeleteBlock();
    }
}

- (void)updateWithUrl:(NSString *)urlStr index:(NSInteger)index isPlaying:(BOOL)isPlaying onDelete:(void (^)(void))onDelete
{
    [self updateWithUrl:urlStr title:nil index:index isPlaying:isPlaying onDelete:onDelete];
}

- (void)updateWithUrl:(NSString *)urlStr title:(nullable NSString *)displayTitle index:(NSInteger)index isPlaying:(BOOL)isPlaying onDelete:(void (^)(void))onDelete
{
    self.onDeleteBlock = onDelete;
    self.indexLb.stringValue = [NSString stringWithFormat:@"%ld", (long)(index + 1)];
    self.titleLb.stringValue = (displayTitle.length > 0) ? displayTitle : ([urlStr lastPathComponent] ?: @"");
    
    if (isPlaying) {
        self.playIconLb.hidden = NO;
        self.titleLb.textColor = [NSColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0];
        self.titleLb.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightBold];
        self.indexLb.textColor = [NSColor colorWithRed:0.35 green:0.75 blue:1.0 alpha:1.0];
    } else {
        self.playIconLb.hidden = YES;
        self.titleLb.textColor = [NSColor whiteColor];
        self.titleLb.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
        self.indexLb.textColor = [NSColor secondaryLabelColor];
    }
}

@end

#pragma mark - MRPlaylistContainerView

@protocol MRPlaylistContainerViewDelegate <NSObject>
@optional
- (NSDragOperation)playlistView:(NSView *)view draggingEntered:(id<NSDraggingInfo>)sender;
- (NSDragOperation)playlistView:(NSView *)view draggingUpdated:(id<NSDraggingInfo>)sender;
- (BOOL)playlistView:(NSView *)view prepareForDragOperation:(id<NSDraggingInfo>)sender;
- (BOOL)playlistView:(NSView *)view performDragOperation:(id<NSDraggingInfo>)sender;
@end

@interface MRPlaylistContainerView : NSView
@property (nonatomic, weak) id<MRPlaylistContainerViewDelegate> delegate;
@end

@implementation MRPlaylistContainerView

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(playlistView:draggingEntered:)]) {
        return [self.delegate playlistView:self draggingEntered:sender];
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(playlistView:draggingUpdated:)]) {
        return [self.delegate playlistView:self draggingUpdated:sender];
    } else if (self.delegate && [self.delegate respondsToSelector:@selector(playlistView:draggingEntered:)]) {
        return [self.delegate playlistView:self draggingEntered:sender];
    }
    return NSDragOperationNone;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(playlistView:prepareForDragOperation:)]) {
        return [self.delegate playlistView:self prepareForDragOperation:sender];
    }
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(playlistView:performDragOperation:)]) {
        return [self.delegate playlistView:self performDragOperation:sender];
    }
    return NO;
}

@end

static NSString * const kMRPlaylistSortAlphabeticalKey = @"MRPlaylistSortAlphabeticalEnabled";

#pragma mark - MRPlaylistViewController

@interface MRPlaylistViewController () <NSTableViewDelegate, NSTableViewDataSource, MRPlaylistContainerViewDelegate>

@property (nonatomic, copy, readwrite) NSArray<NSString *> *playlistItems;
@property (nonatomic, copy) NSArray<NSString *> *rawPlaylist;
@property (nonatomic, copy, readwrite, nullable) NSString *currentlyPlayingUrl;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary *> *playlistMetadata;
@property (nonatomic, assign) BOOL isAlphabeticalSortEnabled;

@property (nonatomic, strong) NSVisualEffectView *vibrantView;
@property (nonatomic, strong) NSView *headerView;
@property (nonatomic, strong) NSTextField *countLb;
@property (nonatomic, strong) MRHoverTextButton *sortBtn;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSView *emptyStateView;

@end

@implementation MRPlaylistViewController

- (void)loadView
{
    MRPlaylistContainerView *container = [[MRPlaylistContainerView alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];
    container.delegate = self;
    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _isAlphabeticalSortEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kMRPlaylistSortAlphabeticalKey];
    [self setupUI];
    [self setupDragAndDrop];
}

- (void)setupUI
{
    self.view.wantsLayer = YES;
    
    // 1. Background Blur
    _vibrantView = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
    _vibrantView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _vibrantView.material = NSVisualEffectMaterialHUDWindow;
    _vibrantView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _vibrantView.state = NSVisualEffectStateActive;
    [self.view addSubview:_vibrantView];
    
    // 2. Header Bar View (with 32pt top inset for macOS window title bar)
    _headerView = [[NSView alloc] init];
    _headerView.translatesAutoresizingMaskIntoConstraints = NO;
    _headerView.wantsLayer = YES;
    _headerView.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.15].CGColor;
    [self.view addSubview:_headerView];
    
    NSView *headerContent = [[NSView alloc] init];
    headerContent.translatesAutoresizingMaskIntoConstraints = NO;
    [_headerView addSubview:headerContent];
    
    NSTextField *titleLb = [[NSTextField alloc] init];
    titleLb.translatesAutoresizingMaskIntoConstraints = NO;
    titleLb.bezeled = NO;
    titleLb.drawsBackground = NO;
    titleLb.editable = NO;
    titleLb.selectable = NO;
    titleLb.stringValue = @"播放列表";
    titleLb.font = [NSFont systemFontOfSize:15 weight:NSFontWeightBold];
    titleLb.textColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    [headerContent addSubview:titleLb];
    
    _countLb = [[NSTextField alloc] init];
    _countLb.translatesAutoresizingMaskIntoConstraints = NO;
    _countLb.bezeled = NO;
    _countLb.drawsBackground = NO;
    _countLb.editable = NO;
    _countLb.selectable = NO;
    _countLb.stringValue = @"(0)";
    _countLb.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    _countLb.textColor = [NSColor secondaryLabelColor];
    [headerContent addSubview:_countLb];
    
    _sortBtn = [[MRHoverTextButton alloc] init];
    _sortBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _sortBtn.target = self;
    _sortBtn.action = @selector(onSortBtnClicked:);
    [headerContent addSubview:_sortBtn];
    [self updateSortButtonUI];
    
    MRHoverTextButton *addBtn = [[MRHoverTextButton alloc] init];
    addBtn.title = @"+ 添加";
    addBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    addBtn.normalColor = [NSColor whiteColor];
    addBtn.hoverColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
    addBtn.target = self;
    addBtn.action = @selector(onAddBtnClicked:);
    [headerContent addSubview:addBtn];
    
    MRHoverTextButton *clearBtn = [[MRHoverTextButton alloc] init];
    clearBtn.title = @"清空";
    clearBtn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    clearBtn.normalColor = [NSColor whiteColor];
    clearBtn.hoverColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
    clearBtn.target = self;
    clearBtn.action = @selector(onClearBtnClicked:);
    [headerContent addSubview:clearBtn];
    
    NSView *sep = [[NSView alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.12].CGColor;
    [_headerView addSubview:sep];
    
    [NSLayoutConstraint activateConstraints:@[
        [_headerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_headerView.heightAnchor constraintEqualToConstant:80],
        
        [headerContent.topAnchor constraintEqualToAnchor:_headerView.topAnchor constant:32],
        [headerContent.leadingAnchor constraintEqualToAnchor:_headerView.leadingAnchor],
        [headerContent.trailingAnchor constraintEqualToAnchor:_headerView.trailingAnchor],
        [headerContent.bottomAnchor constraintEqualToAnchor:_headerView.bottomAnchor],
        
        [titleLb.leadingAnchor constraintEqualToAnchor:headerContent.leadingAnchor constant:16],
        [titleLb.centerYAnchor constraintEqualToAnchor:headerContent.centerYAnchor],
        
        [_countLb.leadingAnchor constraintEqualToAnchor:titleLb.trailingAnchor constant:4],
        [_countLb.centerYAnchor constraintEqualToAnchor:headerContent.centerYAnchor],
        
        [clearBtn.trailingAnchor constraintEqualToAnchor:headerContent.trailingAnchor constant:-14],
        [clearBtn.centerYAnchor constraintEqualToAnchor:headerContent.centerYAnchor],
        
        [addBtn.trailingAnchor constraintEqualToAnchor:clearBtn.leadingAnchor constant:-12],
        [addBtn.centerYAnchor constraintEqualToAnchor:headerContent.centerYAnchor],
        
        [_sortBtn.trailingAnchor constraintEqualToAnchor:addBtn.leadingAnchor constant:-12],
        [_sortBtn.centerYAnchor constraintEqualToAnchor:headerContent.centerYAnchor],
        
        [sep.leadingAnchor constraintEqualToAnchor:_headerView.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:_headerView.trailingAnchor],
        [sep.bottomAnchor constraintEqualToAnchor:_headerView.bottomAnchor],
        [sep.heightAnchor constraintEqualToConstant:1]
    ]];
    
    // 3. ScrollView & TableView
    _scrollView = [[NSScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    [self.view addSubview:_scrollView];
    
    _tableView = [[NSTableView alloc] init];
    _tableView.headerView = nil;
    _tableView.rowHeight = 42;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.target = self;
    _tableView.doubleAction = @selector(onTableDoubleClicked:);
    
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"PlaylistCol"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:col];
    
    _scrollView.documentView = _tableView;
    
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:_headerView.bottomAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    
    // 4. Empty State View
    _emptyStateView = [[NSView alloc] init];
    _emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_emptyStateView];
    
    NSTextField *emptyIconLb = [[NSTextField alloc] init];
    emptyIconLb.translatesAutoresizingMaskIntoConstraints = NO;
    emptyIconLb.bezeled = NO;
    emptyIconLb.drawsBackground = NO;
    emptyIconLb.editable = NO;
    emptyIconLb.selectable = NO;
    emptyIconLb.alignment = NSTextAlignmentCenter;
    emptyIconLb.font = [NSFont systemFontOfSize:36 weight:NSFontWeightLight];
    emptyIconLb.textColor = [NSColor colorWithWhite:0.5 alpha:0.6];
    emptyIconLb.stringValue = @"📑";
    [_emptyStateView addSubview:emptyIconLb];
    
    NSTextField *emptyLb1 = [[NSTextField alloc] init];
    emptyLb1.translatesAutoresizingMaskIntoConstraints = NO;
    emptyLb1.bezeled = NO;
    emptyLb1.drawsBackground = NO;
    emptyLb1.editable = NO;
    emptyLb1.selectable = NO;
    emptyLb1.alignment = NSTextAlignmentCenter;
    emptyLb1.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    emptyLb1.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
    emptyLb1.stringValue = @"播放列表为空";
    [_emptyStateView addSubview:emptyLb1];
    
    NSTextField *emptyLb2 = [[NSTextField alloc] init];
    emptyLb2.translatesAutoresizingMaskIntoConstraints = NO;
    emptyLb2.bezeled = NO;
    emptyLb2.drawsBackground = NO;
    emptyLb2.editable = NO;
    emptyLb2.selectable = NO;
    emptyLb2.alignment = NSTextAlignmentCenter;
    emptyLb2.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    emptyLb2.textColor = [NSColor secondaryLabelColor];
    emptyLb2.stringValue = @"拖拽视频文件到此处添加";
    [_emptyStateView addSubview:emptyLb2];
    
    [NSLayoutConstraint activateConstraints:@[
        [_emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:20],
        [_emptyStateView.widthAnchor constraintEqualToConstant:240],
        
        [emptyIconLb.topAnchor constraintEqualToAnchor:_emptyStateView.topAnchor],
        [emptyIconLb.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        
        [emptyLb1.topAnchor constraintEqualToAnchor:emptyIconLb.bottomAnchor constant:8],
        [emptyLb1.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        
        [emptyLb2.topAnchor constraintEqualToAnchor:emptyLb1.bottomAnchor constant:4],
        [emptyLb2.centerXAnchor constraintEqualToAnchor:_emptyStateView.centerXAnchor],
        [emptyLb2.bottomAnchor constraintEqualToAnchor:_emptyStateView.bottomAnchor]
    ]];
    
    [self updateEmptyState];
}

- (void)setupDragAndDrop
{
    [self.view registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypeURL]];
}

- (void)updatePlaylist:(NSArray<NSString *> *)playlist currentlyPlaying:(nullable NSString *)playingUrl
{
    [self updatePlaylist:playlist currentlyPlaying:playingUrl metadata:nil];
}

- (void)updatePlaylist:(NSArray<NSString *> *)playlist
      currentlyPlaying:(nullable NSString *)playingUrl
              metadata:(nullable NSDictionary<NSString *, NSDictionary *> *)metadata
{
    _rawPlaylist = [playlist copy] ?: @[];
    _currentlyPlayingUrl = [playingUrl copy];
    _playlistMetadata = [metadata copy];
    [self applySortingAndReload];
}

- (void)updateSortButtonUI
{
    if (self.isAlphabeticalSortEnabled) {
        self.sortBtn.title = @"✓ A-Z";
        self.sortBtn.normalColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
        self.sortBtn.hoverColor = [NSColor colorWithRed:255.0/255.0 green:80.0/255.0 blue:80.0/255.0 alpha:1.0];
    } else {
        self.sortBtn.title = @"A-Z";
        self.sortBtn.normalColor = [NSColor whiteColor];
        self.sortBtn.hoverColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
    }
}

- (NSString *)displayTitleForURL:(NSString *)url
{
    NSString *title = self.playlistMetadata[url][@"title"];
    if (title.length > 0) return title;
    return [url lastPathComponent] ?: @"";
}

- (void)applySortingAndReload
{
    if (self.isAlphabeticalSortEnabled && self.rawPlaylist.count > 0) {
        __weakSelf__
        self.playlistItems = [self.rawPlaylist sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
            __strongSelf__
            NSString *name1 = [self displayTitleForURL:obj1];
            NSString *name2 = [self displayTitleForURL:obj2];
            return [name1 localizedStandardCompare:name2];
        }];
    } else {
        self.playlistItems = [self.rawPlaylist copy];
    }
    
    self.countLb.stringValue = [NSString stringWithFormat:@"(%lu)", (unsigned long)self.playlistItems.count];
    [self updateSortButtonUI];
    [self updateEmptyState];
    [self.tableView reloadData];
}

- (void)updateEmptyState
{
    BOOL isEmpty = (_playlistItems.count == 0);
    _emptyStateView.hidden = !isEmpty;
    _scrollView.hidden = isEmpty;
}

#pragma mark - Actions

- (void)onSortBtnClicked:(id)sender
{
    self.isAlphabeticalSortEnabled = !self.isAlphabeticalSortEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.isAlphabeticalSortEnabled forKey:kMRPlaylistSortAlphabeticalKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self applySortingAndReload];
}

- (void)onAddBtnClicked:(id)sender
{
    if (self.onAddFilesRequested) {
        self.onAddFilesRequested();
    }
}

- (void)onClearBtnClicked:(id)sender
{
    if (self.playlistItems.count == 0) return;
    
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"确认清空播放列表？";
    alert.informativeText = @"清空后当前播放列表将被移除。";
    [alert addButtonWithTitle:@"清空"];
    [alert addButtonWithTitle:@"取消"];
    alert.alertStyle = NSAlertStyleWarning;
    
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        if (self.onClearPlaylist) {
            self.onClearPlaylist();
        }
    }
}

- (void)onTableDoubleClicked:(id)sender
{
    NSInteger row = self.tableView.clickedRow;
    if (row >= 0 && row < self.playlistItems.count) {
        NSString *url = self.playlistItems[row];
        if (self.onSelectPlayItem) {
            self.onSelectPlayItem(url, row);
        }
    }
}

#pragma mark - NSTableView DataSource & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.playlistItems.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row
{
    MRPlaylistCellView *cell = [tableView makeViewWithIdentifier:@"MRPlaylistCell" owner:self];
    if (!cell) {
        cell = [[MRPlaylistCellView alloc] initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width, 42)];
        cell.identifier = @"MRPlaylistCell";
    }
    
    if (row >= 0 && row < self.playlistItems.count) {
        NSString *url = self.playlistItems[row];
        BOOL isPlaying = [url isEqualToString:self.currentlyPlayingUrl];
        NSString *title = self.playlistMetadata[url][@"title"];
        
        __weakSelf__
        [cell updateWithUrl:url title:title index:row isPlaying:isPlaying onDelete:^{
            __strongSelf__
            NSInteger rawIndex = [self.rawPlaylist indexOfObject:url];
            if (rawIndex != NSNotFound && self.onRemovePlayItem) {
                self.onRemovePlayItem(rawIndex);
            }
        }];
    }
    
    return cell;
}

#pragma mark - MRPlaylistContainerViewDelegate (NSDraggingDestination)

- (NSDragOperation)playlistView:(NSView *)view draggingEntered:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pboard = [sender draggingPasteboard];
    if ([pboard.types containsObject:NSPasteboardTypeFileURL] || [pboard.types containsObject:NSPasteboardTypeURL]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)playlistView:(NSView *)view draggingUpdated:(id<NSDraggingInfo>)sender
{
    return [self playlistView:view draggingEntered:sender];
}

- (BOOL)playlistView:(NSView *)view prepareForDragOperation:(id<NSDraggingInfo>)sender
{
    return YES;
}

- (BOOL)playlistView:(NSView *)view performDragOperation:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray *urls = [pboard readObjectsForClasses:@[[NSURL class]] options:nil];
    if (urls.count > 0 && self.onFilesDropped) {
        self.onFilesDropped(urls);
        return YES;
    }
    return NO;
}

@end
