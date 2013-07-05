// AFIncrementalStore.m
//
// Copyright (c) 2012 Mattt Thompson (http://mattt.me)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFIncrementalStore.h"
#import "AFIncrementalBacking.h"
#import "AFHTTPClient.h"
#import <objc/runtime.h>

NSString * const AFIncrementalStoreUnimplementedMethodException = @"com.alamofire.incremental-store.exceptions.unimplemented-method";

NSString * const AFIncrementalStoreContextWillFetchRemoteValues = @"AFIncrementalStoreContextWillFetchRemoteValues";
NSString * const AFIncrementalStoreContextWillSaveRemoteValues = @"AFIncrementalStoreContextWillSaveRemoteValues";
NSString * const AFIncrementalStoreContextDidFetchRemoteValues = @"AFIncrementalStoreContextDidFetchRemoteValues";
NSString * const AFIncrementalStoreContextDidSaveRemoteValues = @"AFIncrementalStoreContextDidSaveRemoteValues";
NSString * const AFIncrementalStoreContextWillFetchNewValuesForObject = @"AFIncrementalStoreContextWillFetchNewValuesForObject";
NSString * const AFIncrementalStoreContextDidFetchNewValuesForObject = @"AFIncrementalStoreContextDidFetchNewValuesForObject";
NSString * const AFIncrementalStoreContextWillFetchNewValuesForRelationship = @"AFIncrementalStoreContextWillFetchNewValuesForRelationship";
NSString * const AFIncrementalStoreContextDidFetchNewValuesForRelationship = @"AFIncrementalStoreContextDidFetchNewValuesForRelationship";

NSString * const AFIncrementalStoreRequestOperationsKey = @"AFIncrementalStoreRequestOperations";
NSString * const AFIncrementalStoreFetchedObjectIDsKey = @"AFIncrementalStoreFetchedObjectIDs";
NSString * const AFIncrementalStoreFaultingObjectIDKey = @"AFIncrementalStoreFaultingObjectID";
NSString * const AFIncrementalStoreFaultingRelationshipKey = @"AFIncrementalStoreFaultingRelationship";
NSString * const AFIncrementalStorePersistentStoreRequestKey = @"AFIncrementalStorePersistentStoreRequest";

static char kAFResourceIdentifierObjectKey;

static NSString * const kAFIncrementalStoreResourceIdentifierAttributeName = @"__af_resourceIdentifier";
static NSString * const kAFIncrementalStoreLastModifiedAttributeName = @"__af_lastModified";

static NSString * const kAFReferenceObjectPrefix = @"__af_";

inline NSString * AFReferenceObjectFromResourceIdentifier(NSString *resourceIdentifier) {
    if (!resourceIdentifier) {
        return nil;
    }
    
    return [kAFReferenceObjectPrefix stringByAppendingString:resourceIdentifier];    
}

inline NSString * AFResourceIdentifierFromReferenceObject(id referenceObject) {
    if (!referenceObject) {
        return nil;
    }
    
    NSString *string = [referenceObject description];
    return [string hasPrefix:kAFReferenceObjectPrefix] ? [string substringFromIndex:[kAFReferenceObjectPrefix length]] : string;
}

static inline void AFSaveManagedObjectContextOrThrowInternalConsistencyException(NSManagedObjectContext *managedObjectContext) {
    NSError *error = nil;
    if (![managedObjectContext save:&error]) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[error localizedFailureReason] userInfo:[NSDictionary dictionaryWithObject:error forKey:NSUnderlyingErrorKey]];
    }
}

static inline void AFSaveBackingOrThrowInternalConsistencyException(AFIncrementalBacking *backing) {
    NSError *error = nil;
    if (![backing save:&error]) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[error localizedFailureReason] userInfo:[NSDictionary dictionaryWithObject:error forKey:NSUnderlyingErrorKey]];
    }
}

@interface NSManagedObject (_AFIncrementalStore)
@property (readwrite, nonatomic, copy, setter = af_setResourceIdentifier:) NSString *af_resourceIdentifier;
@end

@implementation NSManagedObject (_AFIncrementalStore)
@dynamic af_resourceIdentifier;

- (NSString *)af_resourceIdentifier {
    NSString *identifier = (NSString *)objc_getAssociatedObject(self, &kAFResourceIdentifierObjectKey);
    
    if (!identifier) {
        if ([self.objectID.persistentStore isKindOfClass:[AFIncrementalStore class]]) {
            id referenceObject = [(AFIncrementalStore *)self.objectID.persistentStore referenceObjectForObjectID:self.objectID];
            if ([referenceObject isKindOfClass:[NSString class]]) {
                return AFResourceIdentifierFromReferenceObject(referenceObject);
            }
        }
    }
    
    return identifier;
}

- (void)af_setResourceIdentifier:(NSString *)resourceIdentifier {
    objc_setAssociatedObject(self, &kAFResourceIdentifierObjectKey, resourceIdentifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@end

#pragma mark -

@implementation AFIncrementalStore {
@private
    NSCache *_backingObjectIDByObjectID;
    NSMutableDictionary *_registeredObjectIDsByEntityNameAndNestedResourceIdentifier;
    NSPersistentStoreCoordinator *_backingPersistentStoreCoordinator;
    AFIncrementalBacking *_backing;
}
@synthesize HTTPClient = _HTTPClient;
@synthesize backingPersistentStoreCoordinator = _backingPersistentStoreCoordinator;

+ (NSString *)type {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +type. Must be overridden in a subclass", nil) userInfo:nil]);
}

+ (NSManagedObjectModel *)model {
    @throw([NSException exceptionWithName:AFIncrementalStoreUnimplementedMethodException reason:NSLocalizedString(@"Unimplemented method: +model. Must be overridden in a subclass", nil) userInfo:nil]);
}

#pragma mark -

- (void)notifyManagedObjectContext:(NSManagedObjectContext *)context
             aboutRequestOperation:(AFHTTPRequestOperation *)operation
                   forFetchRequest:(NSFetchRequest *)fetchRequest
                  fetchedObjectIDs:(NSArray *)fetchedObjectIDs
{
    NSString *notificationName = [operation isFinished] ? AFIncrementalStoreContextDidFetchRemoteValues : AFIncrementalStoreContextWillFetchRemoteValues;
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:[NSArray arrayWithObject:operation] forKey:AFIncrementalStoreRequestOperationsKey];
    [userInfo setObject:fetchRequest forKey:AFIncrementalStorePersistentStoreRequestKey];
    if ([operation isFinished] && fetchedObjectIDs) {
        [userInfo setObject:fetchedObjectIDs forKey:AFIncrementalStoreFetchedObjectIDsKey];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:context userInfo:userInfo];
}

- (void)notifyManagedObjectContext:(NSManagedObjectContext *)context
            aboutRequestOperations:(NSArray *)operations
             forSaveChangesRequest:(NSSaveChangesRequest *)saveChangesRequest
{
    NSString *notificationName = [[operations lastObject] isFinished] ? AFIncrementalStoreContextDidSaveRemoteValues : AFIncrementalStoreContextWillSaveRemoteValues;
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:operations forKey:AFIncrementalStoreRequestOperationsKey];
    [userInfo setObject:saveChangesRequest forKey:AFIncrementalStorePersistentStoreRequestKey];

    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:context userInfo:userInfo];
}

- (void)notifyManagedObjectContext:(NSManagedObjectContext *)context
             aboutRequestOperation:(AFHTTPRequestOperation *)operation
       forNewValuesForObjectWithID:(NSManagedObjectID *)objectID
{
    NSString *notificationName = [operation isFinished] ? AFIncrementalStoreContextWillFetchNewValuesForObject : AFIncrementalStoreContextDidFetchNewValuesForObject;

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:[NSArray arrayWithObject:operation] forKey:AFIncrementalStoreRequestOperationsKey];
    [userInfo setObject:objectID forKey:AFIncrementalStoreFaultingObjectIDKey];

    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:context userInfo:userInfo];
}

- (void)notifyManagedObjectContext:(NSManagedObjectContext *)context
             aboutRequestOperation:(AFHTTPRequestOperation *)operation
       forNewValuesForRelationship:(NSRelationshipDescription *)relationship
                   forObjectWithID:(NSManagedObjectID *)objectID
{
    NSString *notificationName = [operation isFinished] ? AFIncrementalStoreContextWillFetchNewValuesForRelationship : AFIncrementalStoreContextDidFetchNewValuesForRelationship;

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:[NSArray arrayWithObject:operation] forKey:AFIncrementalStoreRequestOperationsKey];
    [userInfo setObject:objectID forKey:AFIncrementalStoreFaultingObjectIDKey];
    [userInfo setObject:relationship forKey:AFIncrementalStoreFaultingRelationshipKey];

    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:context userInfo:userInfo];
}

#pragma mark -

- (AFIncrementalBacking *)backing {
    if (!_backing) {
        _backing = [[AFIncrementalBacking alloc] initWithManagedPersistentStoreCoordinator:_backingPersistentStoreCoordinator
                                                                     resourceIdentifierKey:kAFIncrementalStoreResourceIdentifierAttributeName];
    }
    
    return _backing;
}

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity
                  withResourceIdentifier:(NSString *)resourceIdentifier
{
    if (!resourceIdentifier) {
        return nil;
    }
    
    NSManagedObjectID *objectID = nil;
    NSMutableDictionary *objectIDsByResourceIdentifier = [_registeredObjectIDsByEntityNameAndNestedResourceIdentifier objectForKey:entity.name];
    if (objectIDsByResourceIdentifier) {
        objectID = [objectIDsByResourceIdentifier objectForKey:resourceIdentifier];
    }
        
    if (!objectID) {
        objectID = [self newObjectIDForEntity:entity referenceObject:AFReferenceObjectFromResourceIdentifier(resourceIdentifier)];
    }
    
    NSParameterAssert([objectID.entity.name isEqualToString:entity.name]);
    
    return objectID;
}

- (NSManagedObjectID *)objectIDForBackingObjectForEntity:(NSEntityDescription *)entity
                                  withResourceIdentifier:(NSString *)resourceIdentifier
{
    if (!resourceIdentifier) {
        return nil;
    }
    
    __block NSManagedObjectID *objectID = nil;
    __block NSError *error = nil;
    
    AFIncrementalBacking *backing = [self backing];
    [backing performBlockAndWait:^{
        objectID = [backing objectIDForEntityName:entity.name resourceIdentifier:resourceIdentifier error:&error];
    }];
    
    if (error) {
        NSLog(@"Error: %@", error);
        return nil;
    }
    
    return objectID;
}

- (void)updateBackingObjectWithID:(NSManagedObjectID *)backingObjectID
withAttributeAndRelationshipValuesFromManagedObject:(NSManagedObject *)managedObject
{
    for (NSRelationshipDescription *relationship in [managedObject.entity.relationshipsByName allValues]) {
        
        if ([managedObject hasFaultForRelationshipNamed:relationship.name]) {
            continue;
        }
        
        id relationshipValue = [managedObject valueForKey:relationship.name];
        if (!relationshipValue) {
            continue;
        }
        
        if ([relationship isToMany]) {
            NSMutableArray *mutableBackingRelationshipObjectIDs = [NSMutableArray arrayWithCapacity:[relationshipValue count]];
            
            for (NSManagedObject *relationshipManagedObject in relationshipValue) {
				if (![[relationshipManagedObject objectID] isTemporaryID]) {
					NSManagedObjectID *backingRelationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:relationshipManagedObject.objectID])];
					if (backingRelationshipObjectID) {
                        [mutableBackingRelationshipObjectIDs addObject:backingRelationshipObjectID];
					}
				}
            }
            
            [[self backing] updateObjectWithID:backingObjectID withObjectIDs:mutableBackingRelationshipObjectIDs forRelationshipName:relationship.name];
        } else {
			if (![[relationshipValue objectID] isTemporaryID]) {
				NSManagedObjectID *backingRelationshipObjectID = [self objectIDForBackingObjectForEntity:relationship.destinationEntity withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:[relationshipValue objectID]])];
				if (backingRelationshipObjectID) {
                    [[self backing] updateObjectWithID:backingObjectID withObjectIDs:@[backingRelationshipObjectID] forRelationshipName:relationship.name];
				}
			}
        }
    }
    
    [[self backing] updateObjectWithID:backingObjectID withAttributes:[managedObject dictionaryWithValuesForKeys:[managedObject.entity.attributesByName allKeys]]];
}

#pragma mark -

- (BOOL)insertOrUpdateObjectsFromRepresentations:(id)representationOrArrayOfRepresentations
                                        ofEntity:(NSEntityDescription *)entity
                                    fromResponse:(NSHTTPURLResponse *)response
                                     withContext:(NSManagedObjectContext *)context
                                           error:(NSError *__autoreleasing *)error
                                 completionBlock:(void (^)(NSArray *managedObjects, NSArray *backingObjectIDs))completionBlock
{
    if (!representationOrArrayOfRepresentations) {
        return NO;
    }

    NSParameterAssert([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]] || [representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]);
    
    if ([representationOrArrayOfRepresentations count] == 0) {
        if (completionBlock) {
            completionBlock([NSArray array], [NSArray array]);
        }
        
        return NO;
    }
    
    AFIncrementalBacking *backing = [self backing];
    NSString *lastModified = [[response allHeaderFields] valueForKey:@"Last-Modified"];

    NSArray *representations = nil;
    if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
        representations = representationOrArrayOfRepresentations;
    } else if ([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
        representations = [NSArray arrayWithObject:representationOrArrayOfRepresentations];
    }

    NSUInteger numberOfRepresentations = [representations count];
    NSMutableArray *mutableManagedObjects = [NSMutableArray arrayWithCapacity:numberOfRepresentations];
    NSMutableArray *mutableBackingObjectIDs = [NSMutableArray arrayWithCapacity:numberOfRepresentations];
    
    for (NSDictionary *representation in representations) {
        NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:entity fromResponse:response];
        NSDictionary *attributes = [self.HTTPClient attributesForRepresentation:representation ofEntity:entity fromResponse:response];
        
        __block NSManagedObject *managedObject = nil;
        [context performBlockAndWait:^{
            managedObject = [context existingObjectWithID:[self objectIDForEntity:entity withResourceIdentifier:resourceIdentifier] error:nil];
        }];
        
        [managedObject setValuesForKeysWithDictionary:attributes];
        
        NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:entity withResourceIdentifier:resourceIdentifier];
        __block NSManagedObjectID *newBackingObjectID = nil;
        
        [backing performBlockAndWait:^{
            if (backingObjectID) {
                newBackingObjectID = backingObjectID;
            } else {
                newBackingObjectID = [backing objectIDForInsertedObjectForEntityName:entity.name resourceIdentifier:resourceIdentifier];
            }
        }];
        [backing updateObjectWithID:newBackingObjectID withAttributes:@{kAFIncrementalStoreResourceIdentifierAttributeName: resourceIdentifier ?: [NSNull null]}];
        [backing updateObjectWithID:newBackingObjectID withAttributes:@{kAFIncrementalStoreLastModifiedAttributeName: lastModified ?: [NSNull null]}];
        [backing updateObjectWithID:newBackingObjectID withAttributes:attributes];
        
        if (!backingObjectID) {
            [context insertObject:managedObject];
        }
        
        NSDictionary *relationshipRepresentations = [self.HTTPClient representationsForRelationshipsFromRepresentation:representation ofEntity:entity fromResponse:response];
        for (NSString *relationshipName in relationshipRepresentations) {
            NSRelationshipDescription *relationship = [[entity relationshipsByName] valueForKey:relationshipName];
            id relationshipRepresentation = [relationshipRepresentations objectForKey:relationshipName];
            if (!relationship || (relationship.isOptional && (!relationshipRepresentation || [relationshipRepresentation isEqual:[NSNull null]]))) {
                continue;
            }
                        
            if (!relationshipRepresentation || [relationshipRepresentation isEqual:[NSNull null]] || [relationshipRepresentation count] == 0) {
                [managedObject setValue:nil forKey:relationshipName];
                [backing updateObjectWithID:newBackingObjectID withObjectIDs:@[] forRelationshipName:relationshipName];
                continue;
            }
            
            [self insertOrUpdateObjectsFromRepresentations:relationshipRepresentation ofEntity:relationship.destinationEntity fromResponse:response withContext:context error:error completionBlock:^(NSArray *managedObjects, NSArray *backingObjectIDs) {
                if ([relationship isToMany]) {
                    if ([relationship isOrdered]) {
                        [managedObject setValue:[NSOrderedSet orderedSetWithArray:managedObjects] forKey:relationship.name];
                    } else {
                        [managedObject setValue:[NSSet setWithArray:managedObjects] forKey:relationship.name];
                    }
                } else {
                    [managedObject setValue:[managedObjects lastObject] forKey:relationship.name];
                }
                [backing updateObjectWithID:newBackingObjectID withObjectIDs:backingObjectIDs forRelationshipName:relationship.name];
            }];
        }
        
        [mutableManagedObjects addObject:managedObject];
        [mutableBackingObjectIDs addObject:newBackingObjectID];
    }
    
    if (completionBlock) {
        completionBlock(mutableManagedObjects, mutableBackingObjectIDs);
    }

    return YES;
}

- (id)executeFetchRequest:(NSFetchRequest *)fetchRequest
              withContext:(NSManagedObjectContext *)context
                    error:(NSError *__autoreleasing *)error
{
    NSURLRequest *request = [self.HTTPClient requestForFetchRequest:fetchRequest withContext:context];
    if ([request URL]) {
        AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
            [context performBlockAndWait:^{
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsOfEntity:fetchRequest.entity fromResponseObject:responseObject];
        
                [self prefetchObjectsForRepresentationOrArrayOfRepresentations:representationOrArrayOfRepresentations ofEntity:fetchRequest.entity fromResponse:operation.response];
                NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
                childContext.parentContext = context;
                childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;

                [childContext performBlockAndWait:^{
                    [self insertOrUpdateObjectsFromRepresentations:representationOrArrayOfRepresentations ofEntity:fetchRequest.entity fromResponse:operation.response withContext:childContext error:nil completionBlock:^(NSArray *managedObjects, NSArray *backingObjectIDs) {
                        NSSet *childObjects = [childContext registeredObjects];
                        AFSaveManagedObjectContextOrThrowInternalConsistencyException(childContext);

                        AFIncrementalBacking *backing = [self backing];
                        [backing performBlockAndWait:^{
                            AFSaveBackingOrThrowInternalConsistencyException(backing);
                        }];

                        [context performBlockAndWait:^{
                            for (NSManagedObject *childObject in childObjects) {
                                NSManagedObject *parentObject = [context objectWithID:childObject.objectID];
                                [context refreshObject:parentObject mergeChanges:NO];
                            }
                        }];

                        [self notifyManagedObjectContext:context aboutRequestOperation:operation forFetchRequest:fetchRequest fetchedObjectIDs:[managedObjects valueForKeyPath:@"objectID"]];
                    }];
                }];
            }];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
            NSLog(@"Error: %@", error);
            [self notifyManagedObjectContext:context aboutRequestOperation:operation forFetchRequest:fetchRequest fetchedObjectIDs:nil];
        }];

        [self notifyManagedObjectContext:context aboutRequestOperation:operation forFetchRequest:fetchRequest fetchedObjectIDs:nil];
        [self.HTTPClient enqueueHTTPRequestOperation:operation];
    }
    
    AFIncrementalBacking *backing = [self backing];
	NSFetchRequest *backingFetchRequest = [fetchRequest copy];
	backingFetchRequest.entity = [backing entityForName:fetchRequest.entityName];

    switch (fetchRequest.resultType) {
        case NSManagedObjectResultType: {
            return [backing executeFetchRequest:backingFetchRequest error:error usingInstantiator:^NSManagedObject *(NSManagedObjectID *backingObjectID, NSError **outError) {
                NSString *resourceIdentifier = [backing resourceIdentifierForObjectWithID:backingObjectID];
                NSManagedObjectID *objectID = [self objectIDForEntity:fetchRequest.entity withResourceIdentifier:resourceIdentifier];
                NSManagedObject *object = [context objectWithID:objectID];
                object.af_resourceIdentifier = resourceIdentifier;
                return object;
            }];
        }
        case NSManagedObjectIDResultType: {
            NSArray *backingObjectIDs = [backing executeFetchRequest:backingFetchRequest error:error usingInstantiator:nil];
            NSMutableArray *managedObjectIDs = [NSMutableArray arrayWithCapacity:[backingObjectIDs count]];
            
            for (NSManagedObjectID *backingObjectID in backingObjectIDs) {
                NSString *resourceID = [backing resourceIdentifierForObjectWithID:backingObjectID];
                [managedObjectIDs addObject:[self objectIDForEntity:fetchRequest.entity withResourceIdentifier:resourceID]];
            }
            
            return managedObjectIDs;
        }
        case NSDictionaryResultType:
        case NSCountResultType:
            return [backing executeFetchRequest:backingFetchRequest error:error usingInstantiator:nil];
        default:
            return nil;
    }
}

- (id)executeSaveChangesRequest:(NSSaveChangesRequest *)saveChangesRequest
                    withContext:(NSManagedObjectContext *)context
                          error:(NSError *__autoreleasing *)error
{
    NSMutableArray *mutableOperations = [NSMutableArray array];
    AFIncrementalBacking *backing = [self backing];

    if ([self.HTTPClient respondsToSelector:@selector(requestForInsertedObject:)]) {
        for (NSManagedObject *insertedObject in [saveChangesRequest insertedObjects]) {
            NSURLRequest *request = [self.HTTPClient requestForInsertedObject:insertedObject];
            if (!request) {
                [backing performBlockAndWait:^{
                    CFUUIDRef UUID = CFUUIDCreate(NULL);
                    NSString *resourceIdentifier = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, UUID);
                    CFRelease(UUID);
                    insertedObject.af_resourceIdentifier = resourceIdentifier;
                    
                    NSManagedObjectID *backingObjectID = [backing objectIDForInsertedObjectForEntityName:insertedObject.entity.name resourceIdentifier:resourceIdentifier];
                    [backing updateObjectWithID:backingObjectID withAttributes:@{kAFIncrementalStoreResourceIdentifierAttributeName: resourceIdentifier}];
                    [self updateBackingObjectWithID:backingObjectID withAttributeAndRelationshipValuesFromManagedObject:insertedObject];
                    [backing save:nil];
                }];
                
                [insertedObject willChangeValueForKey:@"objectID"];
                [context obtainPermanentIDsForObjects:[NSArray arrayWithObject:insertedObject] error:nil];
                [insertedObject didChangeValueForKey:@"objectID"];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsOfEntity:[insertedObject entity]  fromResponseObject:responseObject];
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *representation = (NSDictionary *)representationOrArrayOfRepresentations;

                    NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:[insertedObject entity] fromResponse:operation.response];
                    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[insertedObject entity] withResourceIdentifier:resourceIdentifier];
                    insertedObject.af_resourceIdentifier = resourceIdentifier;
                    [insertedObject setValuesForKeysWithDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:insertedObject.entity fromResponse:operation.response]];

                    [backing performBlockAndWait:^{
                        NSManagedObjectID *newBackingObjectID = nil;
                        if (backingObjectID) {
                            newBackingObjectID = backingObjectID;
                        }
                        else {
                            newBackingObjectID = [backing objectIDForInsertedObjectForEntityName:insertedObject.entity.name resourceIdentifier:resourceIdentifier];
                        }

                        [backing updateObjectWithID:newBackingObjectID withAttributes:@{kAFIncrementalStoreResourceIdentifierAttributeName: resourceIdentifier ?: [NSNull null]}];
                        [self updateBackingObjectWithID:newBackingObjectID withAttributeAndRelationshipValuesFromManagedObject:insertedObject];
                        [backing save:nil];
                    }];

                    [insertedObject willChangeValueForKey:@"objectID"];
                    [context obtainPermanentIDsForObjects:[NSArray arrayWithObject:insertedObject] error:nil];
                    [insertedObject didChangeValueForKey:@"objectID"];

                    [context refreshObject:insertedObject mergeChanges:NO];
                }
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Insert Error: %@", error);
            }];
            
            [mutableOperations addObject:operation];
        }
    }
    
    if ([self.HTTPClient respondsToSelector:@selector(requestForUpdatedObject:)]) {
        for (NSManagedObject *updatedObject in [saveChangesRequest updatedObjects]) {
            NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[updatedObject entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:updatedObject.objectID])];

            NSURLRequest *request = [self.HTTPClient requestForUpdatedObject:updatedObject];
            if (!request) {
                [backing performBlockAndWait:^{
                    [self updateBackingObjectWithID:backingObjectID withAttributeAndRelationshipValuesFromManagedObject:updatedObject];
                    [backing save:nil];
                }];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsOfEntity:[updatedObject entity]  fromResponseObject:responseObject];
                if ([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *representation = (NSDictionary *)representationOrArrayOfRepresentations;
                    [updatedObject setValuesForKeysWithDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:updatedObject.entity fromResponse:operation.response]];

                    [backing performBlockAndWait:^{
                        [self updateBackingObjectWithID:backingObjectID withAttributeAndRelationshipValuesFromManagedObject:updatedObject];
                        [backing save:nil];
                    }];

                    [context refreshObject:updatedObject mergeChanges:NO];
                }
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Update Error: %@", error);
                [context refreshObject:updatedObject mergeChanges:NO];
            }];
            
            [mutableOperations addObject:operation];
        }
    }
    
    if ([self.HTTPClient respondsToSelector:@selector(requestForDeletedObject:)]) {
        for (NSManagedObject *deletedObject in [saveChangesRequest deletedObjects]) {
            NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[deletedObject entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:deletedObject.objectID])];

            NSURLRequest *request = [self.HTTPClient requestForDeletedObject:deletedObject];
            if (!request) {
                [backing performBlockAndWait:^{
                    [backing deleteObjectWithID:backingObjectID];
                    [backing save:nil];
                }];
                continue;
            }
            
            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                [backing performBlockAndWait:^{
                    [backing deleteObjectWithID:backingObjectID];
                    [backing save:nil];
                }];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Delete Error: %@", error);
            }];
            
            [mutableOperations addObject:operation];
        }
    }
    
    // NSManagedObjectContext removes object references from an NSSaveChangesRequest as each object is saved, so create a copy of the original in order to send useful information in AFIncrementalStoreContextDidSaveRemoteValues notification.
    NSSaveChangesRequest *saveChangesRequestCopy = [[NSSaveChangesRequest alloc] initWithInsertedObjects:[saveChangesRequest.insertedObjects copy] updatedObjects:[saveChangesRequest.updatedObjects copy] deletedObjects:[saveChangesRequest.deletedObjects copy] lockedObjects:[saveChangesRequest.lockedObjects copy]];
    
    [self notifyManagedObjectContext:context aboutRequestOperations:mutableOperations forSaveChangesRequest:saveChangesRequestCopy];

    [self.HTTPClient enqueueBatchOfHTTPRequestOperations:mutableOperations progressBlock:nil completionBlock:^(NSArray *operations) {
        [self notifyManagedObjectContext:context aboutRequestOperations:operations forSaveChangesRequest:saveChangesRequestCopy];
    }];
    
    return [NSArray array];
}

#pragma mark - NSIncrementalStore

- (BOOL)loadMetadata:(NSError *__autoreleasing *)error {
    if (!_backingObjectIDByObjectID) {
        NSMutableDictionary *mutableMetadata = [NSMutableDictionary dictionary];
        [mutableMetadata setValue:[[NSProcessInfo processInfo] globallyUniqueString] forKey:NSStoreUUIDKey];
        [mutableMetadata setValue:NSStringFromClass([self class]) forKey:NSStoreTypeKey];
        [self setMetadata:mutableMetadata];
        
        _backingObjectIDByObjectID = [[NSCache alloc] init];
        _registeredObjectIDsByEntityNameAndNestedResourceIdentifier = [[NSMutableDictionary alloc] init];
        
        NSManagedObjectModel *model = [self.persistentStoreCoordinator.managedObjectModel copy];
        for (NSEntityDescription *entity in model.entities) {
            // Don't add properties for sub-entities, as they already exist in the super-entity
            if ([entity superentity]) {
                continue;
            }
            
            NSAttributeDescription *resourceIdentifierProperty = [[NSAttributeDescription alloc] init];
            [resourceIdentifierProperty setName:kAFIncrementalStoreResourceIdentifierAttributeName];
            [resourceIdentifierProperty setAttributeType:NSStringAttributeType];
            [resourceIdentifierProperty setIndexed:YES];
            
            NSAttributeDescription *lastModifiedProperty = [[NSAttributeDescription alloc] init];
            [lastModifiedProperty setName:kAFIncrementalStoreLastModifiedAttributeName];
            [lastModifiedProperty setAttributeType:NSStringAttributeType];
            [lastModifiedProperty setIndexed:NO];
            
            [entity setProperties:[entity.properties arrayByAddingObjectsFromArray:[NSArray arrayWithObjects:resourceIdentifierProperty, lastModifiedProperty, nil]]];
        }
        
        _backingPersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        
        return YES;
    } else {
        return NO;
    }
}

- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error {
    NSMutableArray *mutablePermanentIDs = [NSMutableArray arrayWithCapacity:[array count]];
    for (NSManagedObject *managedObject in array) {
        NSManagedObjectID *managedObjectID = managedObject.objectID;
        if ([managedObjectID isTemporaryID] && managedObject.af_resourceIdentifier) {
            NSManagedObjectID *objectID = [self objectIDForEntity:managedObject.entity withResourceIdentifier:managedObject.af_resourceIdentifier];
            [mutablePermanentIDs addObject:objectID];
        } else {
            [mutablePermanentIDs addObject:managedObjectID];
        }
    }
    
    return mutablePermanentIDs;
}

- (id)executeRequest:(NSPersistentStoreRequest *)persistentStoreRequest
         withContext:(NSManagedObjectContext *)context
               error:(NSError *__autoreleasing *)error
{
    if (persistentStoreRequest.requestType == NSFetchRequestType) {
        return [self executeFetchRequest:(NSFetchRequest *)persistentStoreRequest withContext:context error:error];
    } else if (persistentStoreRequest.requestType == NSSaveRequestType) {
        return [self executeSaveChangesRequest:(NSSaveChangesRequest *)persistentStoreRequest withContext:context error:error];
    } else {
        NSMutableDictionary *mutableUserInfo = [NSMutableDictionary dictionary];
        [mutableUserInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Unsupported NSFetchRequestResultType, %d", nil), persistentStoreRequest.requestType] forKey:NSLocalizedDescriptionKey];
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:0 userInfo:mutableUserInfo];
        }
        
        return nil;
    }
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError *__autoreleasing *)error
{
    NSString *resourceIdentifier = AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID]);
    
    // Documentation states that “the returned node [...] may include to-one relationship values as instances of NSManagedObjectID”.
    // But when it doesn't, the managed object's to-one relationships become nil after a save request until the managed object turns back into fault.
    // Let's pretend the documentation meant to say “should”.
    
    __block NSMutableDictionary *attributes;
    AFIncrementalBacking *backing = [self backing];
    [backing performBlockAndWait:^{
        NSManagedObjectID *backingObjectID = resourceIdentifier ? [backing objectIDForEntityName:objectID.entity.name resourceIdentifier:resourceIdentifier error:nil] : nil;
        attributes = backingObjectID ? [backing attributesAndToOneRelationshipsForObjectWithID:backingObjectID].mutableCopy : nil;
        [objectID.entity.relationshipsByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSRelationshipDescription *relationship, BOOL *stop) {
            if (relationship.isToMany || nil == attributes[name]) {
                return;
            }
            NSString *resourceID = [backing resourceIdentifierForObjectWithID:attributes[name]];
            attributes[name] = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceID];
        }];
    }];
    
    NSDictionary *attributeValues = attributes ?: [NSDictionary dictionary];
    NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:attributeValues version:CFAbsoluteTimeGetCurrent()];
    
    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteAttributeValuesForObjectWithID:inManagedObjectContext:)] && [self.HTTPClient shouldFetchRemoteAttributeValuesForObjectWithID:objectID inManagedObjectContext:context]) {
        if (attributeValues) {
            NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
            childContext.parentContext = context;
            childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
            
            NSMutableURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForObjectWithID:objectID withContext:context];
            NSString *lastModified = [attributeValues objectForKey:kAFIncrementalStoreLastModifiedAttributeName];
            if (lastModified) {
                [request setValue:lastModified forHTTPHeaderField:@"Last-Modified"];
            }
            
            if ([request URL]) {
                if ([attributeValues valueForKey:kAFIncrementalStoreLastModifiedAttributeName]) {
                    [request setValue:[[attributeValues valueForKey:kAFIncrementalStoreLastModifiedAttributeName] description] forHTTPHeaderField:@"If-Modified-Since"];
                }

                AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, NSDictionary *representation) {
                    [childContext performBlock:^{
                        NSManagedObject *managedObject = [childContext existingObjectWithID:objectID error:nil];

                        NSMutableDictionary *mutableAttributeValues = [attributeValues mutableCopy];
                        [mutableAttributeValues removeObjectsForKeys:objectID.entity.relationshipsByName.allKeys];
                        [mutableAttributeValues addEntriesFromDictionary:[self.HTTPClient attributesForRepresentation:representation ofEntity:managedObject.entity fromResponse:operation.response]];
                        [mutableAttributeValues removeObjectForKey:kAFIncrementalStoreResourceIdentifierAttributeName];
                        [mutableAttributeValues removeObjectForKey:kAFIncrementalStoreLastModifiedAttributeName];
                        [managedObject setValuesForKeysWithDictionary:mutableAttributeValues];

                        NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
                        if (backingObjectID) {
                            [[self backing] updateObjectWithID:backingObjectID withAttributes:mutableAttributeValues];
                        }

                        NSString *lastModified = [[operation.response allHeaderFields] valueForKey:@"Last-Modified"];
                        if (lastModified && backingObjectID) {
                            [[self backing] updateObjectWithID:backingObjectID withAttributes:@{kAFIncrementalStoreLastModifiedAttributeName: lastModified}];
                        }

                        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSManagedObjectContextDidSaveNotification object:childContext queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                            [context mergeChangesFromContextDidSaveNotification:note];
                        }];

                        [childContext performBlockAndWait:^{
                            AFSaveManagedObjectContextOrThrowInternalConsistencyException(childContext);

                            AFIncrementalBacking *backing = [self backing];
                            [backing performBlockAndWait:^{
                                AFSaveBackingOrThrowInternalConsistencyException(backing);
                            }];
                        }];
                        
                        [[NSNotificationCenter defaultCenter] removeObserver:observer];

                        [self notifyManagedObjectContext:context aboutRequestOperation:operation forNewValuesForObjectWithID:objectID];
                    }];

                } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                    NSLog(@"Error: %@, %@", operation, error);
                    [self notifyManagedObjectContext:context aboutRequestOperation:operation forNewValuesForObjectWithID:objectID];
                }];

                [self notifyManagedObjectContext:context aboutRequestOperation:operation forNewValuesForObjectWithID:objectID];
                [self.HTTPClient enqueueHTTPRequestOperation:operation];
            }
        }
    }
    
    return node;
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError *__autoreleasing *)error
{
    if ([self.HTTPClient respondsToSelector:@selector(shouldFetchRemoteValuesForRelationship:forObjectWithID:inManagedObjectContext:)] && [self.HTTPClient shouldFetchRemoteValuesForRelationship:relationship forObjectWithID:objectID inManagedObjectContext:context]) {
        NSURLRequest *request = [self.HTTPClient requestWithMethod:@"GET" pathForRelationship:relationship forObjectWithID:objectID withContext:context];
        
        if ([request URL] && ![[context existingObjectWithID:objectID error:nil] hasChanges]) {
            NSManagedObjectContext *childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
            childContext.parentContext = context;
            childContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;

            AFHTTPRequestOperation *operation = [self.HTTPClient HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
                [childContext performBlock:^{
                    id representationOrArrayOfRepresentations = [self.HTTPClient representationOrArrayOfRepresentationsOfEntity:relationship.destinationEntity fromResponseObject:responseObject];
                    [self prefetchObjectsForRepresentationOrArrayOfRepresentations:representationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:responseObject];
                
                    [self insertOrUpdateObjectsFromRepresentations:representationOrArrayOfRepresentations ofEntity:relationship.destinationEntity fromResponse:operation.response withContext:childContext error:nil completionBlock:^(NSArray *managedObjects, NSArray *backingObjectIDs) {
                        NSManagedObject *managedObject = [childContext objectWithID:objectID];
                        
						NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];

                        if ([relationship isToMany]) {
                            if ([relationship isOrdered]) {
                                [managedObject setValue:[NSOrderedSet orderedSetWithArray:managedObjects] forKey:relationship.name];
                            } else {
                                [managedObject setValue:[NSSet setWithArray:managedObjects] forKey:relationship.name];
                            }
                        } else {
                            [managedObject setValue:[managedObjects lastObject] forKey:relationship.name];
                        }
                        
                        if (backingObjectID) {
                            [[self backing] updateObjectWithID:backingObjectID withObjectIDs:backingObjectIDs forRelationshipName:relationship.name];
                        }
                        
                        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:NSManagedObjectContextDidSaveNotification object:childContext queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                            [context mergeChangesFromContextDidSaveNotification:note];
                        }];

                        [childContext performBlockAndWait:^{
                            AFSaveManagedObjectContextOrThrowInternalConsistencyException(childContext);

                            AFIncrementalBacking *backing = [self backing];
                            [backing performBlockAndWait:^{
                                AFSaveBackingOrThrowInternalConsistencyException(backing);
                            }];
                        }];

                        [[NSNotificationCenter defaultCenter] removeObserver:observer];

                        [self notifyManagedObjectContext:context aboutRequestOperation:operation forNewValuesForRelationship:relationship forObjectWithID:objectID];
                    }];
                }];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                NSLog(@"Error: %@, %@", operation, error);
                [self notifyManagedObjectContext:context aboutRequestOperation:operation forNewValuesForRelationship:relationship forObjectWithID:objectID];
            }];

            [self.HTTPClient enqueueHTTPRequestOperation:operation];
        }
    }
    
    NSManagedObjectID *backingObjectID = [self objectIDForBackingObjectForEntity:[objectID entity] withResourceIdentifier:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
    
    if (backingObjectID) {
        NSArray *backingRelationshipObjectIDs = [[self backing] objectIDsForRelationshipName:relationship.name forObjectWithID:backingObjectID];
        if ([relationship isToMany]) {
            NSMutableArray *mutableObjects = [NSMutableArray arrayWithCapacity:[backingRelationshipObjectIDs count]];
            for (NSManagedObjectID *backingRelationshipObjectID in backingRelationshipObjectIDs) {
                NSString *resourceIdentifier = [[self backing] resourceIdentifierForObjectWithID:backingRelationshipObjectID];
                NSManagedObjectID *objectID = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceIdentifier];
                [mutableObjects addObject:objectID];
            }
                        
            return mutableObjects;            
        } else {
            NSManagedObjectID *backingRelationshipObjectID = [backingRelationshipObjectIDs lastObject];
            NSString *resourceIdentifier = backingRelationshipObjectID ? [[self backing] resourceIdentifierForObjectWithID:backingRelationshipObjectID] : nil;
            NSManagedObjectID *objectID = [self objectIDForEntity:relationship.destinationEntity withResourceIdentifier:resourceIdentifier];
            
            return objectID ?: [NSNull null];
        }
    } else {
        if ([relationship isToMany]) {
            return [NSArray array];
        } else {
            return [NSNull null];
        }
    }
}

- (void)managedObjectContextDidRegisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidRegisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        id referenceObject = [self referenceObjectForObjectID:objectID];
        if (!referenceObject) {
            continue;
        }
        
        NSMutableDictionary *objectIDsByResourceIdentifier = [_registeredObjectIDsByEntityNameAndNestedResourceIdentifier objectForKey:objectID.entity.name] ?: [NSMutableDictionary dictionary];
        [objectIDsByResourceIdentifier setObject:objectID forKey:AFResourceIdentifierFromReferenceObject(referenceObject)];
        
        [_registeredObjectIDsByEntityNameAndNestedResourceIdentifier setObject:objectIDsByResourceIdentifier forKey:objectID.entity.name];
    }
}

- (void)managedObjectContextDidUnregisterObjectsWithIDs:(NSArray *)objectIDs {
    [super managedObjectContextDidUnregisterObjectsWithIDs:objectIDs];
    
    for (NSManagedObjectID *objectID in objectIDs) {
        [[_registeredObjectIDsByEntityNameAndNestedResourceIdentifier objectForKey:objectID.entity.name] removeObjectForKey:AFResourceIdentifierFromReferenceObject([self referenceObjectForObjectID:objectID])];
    }
}

#pragma mark - Prefetching

- (void)prefetchObjectsForRepresentationOrArrayOfRepresentations:(id)representationOrArrayOfRepresentations
                                                        ofEntity:(NSEntityDescription *)entity fromResponse:(NSHTTPURLResponse *)response
{
    NSArray *representations = nil;
    
    if ([representationOrArrayOfRepresentations isKindOfClass:[NSArray class]]) {
        representations = representationOrArrayOfRepresentations;
    }
    else if([representationOrArrayOfRepresentations isKindOfClass:[NSDictionary class]]) {
        representations = @[representationOrArrayOfRepresentations];
    }
    else {
        return;
    }
    
    for (NSDictionary *representation in representations)
    {
        NSString *resourceIdentifier = [self.HTTPClient resourceIdentifierForRepresentation:representation ofEntity:entity fromResponse:response];
        if (resourceIdentifier) {
            [[self backing] prefetchObjectForEntityName:entity.name resourceIdentifier:resourceIdentifier];
        }
        
        NSDictionary *relationshipRepresentations = [self.HTTPClient representationsForRelationshipsFromRepresentation:representation ofEntity:entity fromResponse:response];
        [relationshipRepresentations enumerateKeysAndObjectsUsingBlock:^(NSString *name, id relationshipRepresentation, BOOL *stop) {
            NSRelationshipDescription *relationship = entity.relationshipsByName[name];
            if (!relationship || [relationshipRepresentation isEqual:[NSNull null]]) {
                return;
            }
            [self prefetchObjectsForRepresentationOrArrayOfRepresentations:relationshipRepresentation ofEntity:relationship.destinationEntity fromResponse:response];
        }];
    }
}

@end
