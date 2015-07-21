//
//  FileUploadMessage.m
//  BabyunCore
//
//  Created by venking on 15/6/15.
//  Copyright (c) 2015年 babyun. All rights reserved.
//

#import "FileUploadMessage.h"

@implementation ParameterOption

- (id) initWithDictionary:(NSDictionary *)option
{
    if (self = [super init])
    {
        _model = [option objectForKey:@"BeeQueueModel"];
        _blockMessage = [option objectForKey:@"BlockBeeMessage"];
        _result = [option objectForKey:@"UPYunResult"];
    }
    return self;
}
@end

@interface FileUploadMessage()
{
#ifdef FILE_UPLOAD_MESSAGE_MULTI_THREAD
    NSOperationQueue * m_blockQueues; // 每个文件一个线程块
#endif
}
@end

@implementation FileUploadMessage

- (void) setupParam
{
    if (!self.url)
    {
        self.url = [NSString stringWithFormat:@"%@/%@/", [UPYunUpload API_SERVER], [UPYunUpload BUCKET]];
    }
    
    if (!self.formAPI)
    {
        self.formAPI = [UPYunUpload PASSCODE];
    }
}

- (void) initParam
{
    [UPYunUpload setBlockSize:202500];
#ifdef FILE_UPLOAD_MESSAGE_MULTI_THREAD
    if (!m_blockQueues)
    {
        m_blockQueues = [[NSOperationQueue alloc] init];
        m_blockQueues.maxConcurrentOperationCount = [UPYunUpload MAX_THREAD_NUMBER];
    }
#endif
}

- (BeeQueueModel *) fillModel:(BeeQueueModel *)model
{
    if (0 == model.serverPath.length)
    {
        model.serverPath = [NSString stringWithFormat:@"/images/test/test_%@.txt", [[NSDate date] stringWithDateFormat:@"yyyyMMddhhmmss"]];
    }
    
    if (model && model.localPath)
    {
        NSFileManager * fileManager = [NSFileManager defaultManager];
        if ([fileManager isReadableFileAtPath:model.localPath])
        {
            model.data = [NSData dataWithContentsOfFile:model.localPath];
        }
        else
        {
            return nil;
        }
    }
    
    return model;
}

- (void)routine
{
    BACKGROUND_BEGIN
    {
        [self initParam];
        
        while (YES)
        {
            __weak BeeQueueModel * model = nil;
            if (nil == (model = [BeeQueue getFirstDataByQueue:[UPYunUpload UPYUN_DATA_QUEUE]]))
            {
                sleep(5);
                continue;
            }
            if (!self.url || !self.formAPI)
            {
                [self setupParam];
            }

#ifdef FILE_UPLOAD_MESSAGE_MULTI_THREAD
            NSBlockOperation * file = [NSBlockOperation blockOperationWithBlock:^{
#endif
                if ([self fillModel:model])
                {
                    [self demonWithModel:model];
                }
#ifdef FILE_UPLOAD_MESSAGE_MULTI_THREAD
            }];
            [m_blockQueues addOperation:file];
#endif
        }
    }
    BACKGROUND_COMMIT
}

- (void) demonWithModel:(BeeQueueModel *)model
{
    BeeMessage * file = [BeeMessage message];
    @weakify(file);
    
    file.whenSending = [^
    {
        @normalize(file);
        NSDictionary * group = [UPYunUpload parameterGroupWithData:model.data path:model.serverPath];
        NSDictionary * param = [UPYunUpload requestParameterByParameterGroup:group condition:self.formAPI];
        
        file.HTTP_POST(self.url)
        .HEADER(@"Content-Type", @"application/x-www-form-urlencoded")
        .PARAM(param);
    } copy];
    
    file.whenSucceed = [^
    {
        @normalize(file);
        NSDictionary * result = file.responseJSONDictionary;
        
        
        UADHTTPCache * uploadCache = [[UADHTTPCache alloc] initWithLocalPath:model.localPath
                                                            server:model.serverPath
                                                      blockSize:[UPYunUpload BLOCK_SIZE]];
        
        uploadCache.LOAD(); // 加载指定文件缓存
        
        if (result)
        {
            UPYunResult * resultInfo = [[UPYunResult alloc] initWithDictionary:result];
            // 上传块需要用的参数
            ParameterOption * option = [[ParameterOption alloc] init];
            option.model = model;
            option.result = resultInfo;
            option.cache = uploadCache;
            
            [self childBlock:option];
        }
    } copy];
    
    file.whenFailed = [^
    {
        @normalize(file);
        if (file.responseString)
        {
            [BeeQueue failedKey:model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
            ERROR(@"{NAME:%@,KEY:%@} 请求失败! [%@]", model.name, model.key, file.responseString);
        }
    } copy];
    
    file.whenCancelled = [^
    {
        INFO(@"");
    } copy];
    
    file.whenWaiting = [^
    {
        // 块上传完成，进行缓存记录
    } copy];
    
    [file send];
}

- (void) childBlock:(ParameterOption *)option
{
    NSArray * datas = [UPYunUpload subData:option.model.data];
    option.model.data = nil;
    
    if (option.result && datas.count != option.result.blockNumber)
    {
        ERROR(@"[ERROR]:{NAME:%@,KEY:%@} 应答数据块与实际不符!", option.model.name, option.model.key);
        return ;
    }
    
    // 分块数据上传
    for (NSInteger index = 0; index < datas.count;)
    {
        if (option.model && QUEUE_DATA_PAUSE == option.model.state)
        {
            [BeeQueue pauseKey:option.model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
            option.model = nil;
            break;
        }
        else if (option.model && QUEUE_DATA_REMOVE == option.model.state)
        {
            [BeeQueue removeKey:option.model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
            option.model = nil;
            break ;
        }
        
        if (1.0f == [option.cache.progress integerValue]
            || (NSOrderedSame == [option.cache.fileMD5 compare:option.model.key]
                && YES == [option.cache existWithObject:[NSString stringWithFormat:@"%lu", index]]))
        {
            continue;
        }
        
        NSData * data = datas[index];
        NSDictionary * group = @{@"save_token":option.result.saveToken,
                                 @"expiration":EXPIRED_TIME,
                                 @"block_index":@(index),
                                 @"block_hash":[data MD5HexDigest]};
        
        NSMutableDictionary * parameter = [[UPYunUpload requestParameterByParameterGroup:group condition:option.result.tokenSecret] mutableCopy];
        [parameter setObject:data forKey:@"file"];
        
        option.blockMessage = nil;
        NSDictionary * userInfo = @{@"group":group,
                                    @"parameter":parameter,
                                    @"option":option};
        
#ifdef FILE_UPLOAD_MESSAGE_MULTI_THREAD
        self.UPLOAD(userInfo, 0);
#else
        [self uploadBlock:userInfo count:0];
#endif
        
        ++index; // 控制索引
    }
}

- (UploadBlock)UPLOAD
{
    UploadBlock block = ^ void (NSDictionary * userInfo, NSInteger count){
        [self uploadBlock:userInfo count:count];
    };
    return [block copy];
}

- (void) uploadBlock:(NSDictionary *)userInfo count:(NSUInteger)count
{
    NSDictionary * dict = userInfo;
    
    NSMutableDictionary * parameter = [dict objectForKey:@"parameter"];
    NSDictionary * group = [dict objectForKey:@"group"];
    ParameterOption * option = [dict objectForKey:@"option"];
    NSData * data = [parameter objectForKey:@"file"];
    INFO(@"将要上传的数据信息. index:%@, expiration:%@, size:%li, thread:%@",
         [group objectForKey:@"block_index"],
         [group objectForKey:@"expiration"],
         data.length, [NSThread currentThread]);
    
    BeeMessage * block = [BeeMessage message];
    
    ++count;
    if (nil != data)
    {
        [parameter removeObjectForKey:@"file"];
        
        block.HTTP_POST(self.url)
        .HEADER(@"Content-Type", @"multipart/form-data")
        .FILE(@"file", data)
        .PARAM(parameter);
        
        [parameter setValue:data forKey:@"file"];
    }
    else
    {
        block.HTTP_POST(self.url)
        .HEADER(@"Content-Type", @"application/x-www-form-urlencoded")
        .PARAM(parameter);
    }
    
    @weakify(block);
    block.whenUpdate = ^{
        @normalize(block);
        // 当上传暂停时，需求正在上传的块
        if (QUEUE_DATA_PAUSE == option.model.state)
        {
            [block cancel];
            [BeeQueue pauseKey:option.model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
        }
        else if (QUEUE_DATA_REMOVE == option.model.state)
        {
            [block cancel];
            [BeeQueue removeKey:option.model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
        }
    };
    
    // 实时更新处理进度
    block.whenProgressed = ^
    {
    };
    
    // 处理成功
    block.whenSucceed = ^
    {
        @normalize(block);
        NSDictionary * result = block.responseJSONDictionary;
        UPYunResult * paramInfo = nil;
        
        if (nil != data)
        {
            paramInfo = [[UPYunResult alloc] initWithDictionary:result];
            NSUInteger finished = 0;
            for (NSInteger i = 0; i < paramInfo.blockNumber; ++i)
            {
                if (1 == [paramInfo.blockState[i] integerValue])
                {
                    ++finished;
                }
            }
            
            CGFloat progress = (CGFloat)finished / paramInfo.blockNumber;
            INFO(@"文件 %@ 上传进度 ：%f", option.model.localPath, progress);
            if (1.0f == progress)
            {
                [self fileMergeWithOption:option];
            }
            
            if (option.model.whenProgress)
            {
                option.model.whenProgress(progress);
            }
            
            option.cache.progress = @(progress);
            [option.cache addObject:[group objectForKey:@"block_index"]];
        }
        else
        {
            // 合并操作完成，整个文件上传完成。
            [BeeQueue successKey:option.model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
            INFO(@"SUCESS : %@", parameter);
            option.cache.progress = @(1.0f);
        }
        
        option.cache.SAVE();
    };
    
    // 处理失败
    block.whenFailed = ^
    {
        if ([UPYunUpload MAX_RETRY_NUMBER] > count)
        {
            @normalize(block);
            NSString * index = [group objectForKey:@"block_index"];
            if (nil == index)
            {
                index = @"合并";
            }
            else
            {
                index = [NSString stringWithFormat:@"第 %@ 块", index];
            }
            INFO(@"文件 %@ %@ 第 %i 次 上传失败[块大小%li]。 \n %@", option.model.localPath, index, count, data.length, block.responseJSONDictionary);
            [self uploadBlock:userInfo count:count];
        }
        
        [BeeQueue failedKey:option.model.key ofQueue:[UPYunUpload UPYUN_DATA_QUEUE]];
    };
    
    [block send];
}

- (void) fileMergeWithOption:(ParameterOption *)option
{
    NSDictionary * group = @{@"save_token":option.result.saveToken,
                             @"expiration":EXPIRED_TIME};
    
    NSMutableDictionary * parameter = [[UPYunUpload requestParameterByParameterGroup:group condition:option.result.tokenSecret] mutableCopy];
    NSDictionary * userInfo = @{@"group":group,
                                @"parameter":parameter,
                                @"option":option};
    [self uploadBlock:userInfo count:0];
}

@end