// AFIncrementalBacking.m
//
// Copyright (c) 2013 Octiplex
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

#import "AFIncrementalBacking.h"

static NSString *const kAFIncrementalBackingErrorDomain = @"AFIncrementalBackingError";

@implementation AFIncrementalBacking
{
    NSManagedObjectContext  *_managedObjectContext;
    NSMutableDictionary     *_objectIDsByPath;
    NSMutableDictionary     *_resourceIdentifiersByObjectID;
    NSMutableDictionary     *_waitingResourceIdentifiersByEntityName;
}

#pragma mark - init

- (id)initWithManagedPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)persistentStoreCoordinator
                          resourceIdentifierKey:(NSString *)resourceIdentifierKey
{
    if ( ! (self = [super init]) )
        return nil;
    
    _persistentStoreCoordinator = persistentStoreCoordinator;
    _resourceIdentifierKey = resourceIdentifierKey.copy;
    _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    _managedObjectContext.persistentStoreCoordinator = persistentStoreCoordinator;
    _managedObjectContext.retainsRegisteredObjects = YES;
    _objectIDsByPath = [NSMutableDictionary new];
    _resourceIdentifiersByObjectID = [NSMutableDictionary new];
    _waitingResourceIdentifiersByEntityName = [NSMutableDictionary new];
    return self;
}

- (id)init
{
    return [self initWithManagedPersistentStoreCoordinator:nil resourceIdentifierKey:nil];
}

#pragma mark - Fetching

- (void)prefetchObjectForEntityName:(NSString *)entityName resourceIdentifier:(NSString *)resourceIdentifier
{
    NSString *path = [self pathForEntityName:entityName resourceIdentifier:resourceIdentifier];
    if ( _objectIDsByPath[path] ) {
        return;
    }
    
    NSMutableSet *waitingResourceIdentifiers = _waitingResourceIdentifiersByEntityName[entityName];
    if ( ! waitingResourceIdentifiers ) {
        waitingResourceIdentifiers = [NSMutableSet new];
        _waitingResourceIdentifiersByEntityName[entityName] = waitingResourceIdentifiers;
    }
    
    [waitingResourceIdentifiers addObject:resourceIdentifier];
}

- (NSArray *)executeFetchRequest:(NSFetchRequest *)request
                           error:(NSError **)outError
               usingInstantiator:(NSManagedObject *(^)(NSManagedObjectID *objectID, NSError **outError))instantiator
{
    if ( NSManagedObjectResultType == request.resultType && ! instantiator ) {
        // You need to provide a block for instantiating managed objects
        // Don't expect me to return my own objects: they're private
        [NSException raise:NSInvalidArgumentException
                    format:@"*** %s: cannot execute a NSManagedObjectResultType fetch request without instantiator.", __PRETTY_FUNCTION__];
    }
    
    NSArray *results = [_managedObjectContext executeFetchRequest:request error:outError];

    if ( results && NSManagedObjectResultType == request.resultType )
    {
        NSMutableArray *objects = [NSMutableArray arrayWithCapacity:results.count];
        for ( NSManagedObject *result in results ) {
            NSManagedObject *object = instantiator(result.objectID, outError);
            if ( ! object ) {
                return nil;
            }
            if ( ! request.returnsObjectsAsFaults ) {
                [object willAccessValueForKey:nil];
                [object didAccessValueForKey:nil];
            }
            [objects addObject:object];
        }
        results = objects;
    }
    
    return results;
}

- (NSManagedObjectID *)fetchObjectIDForEntityName:(NSString *)entityName resourceIdentifier:(id)resourceIdentifier error:(NSError **)outError
{    
    NSMutableSet *waitingResourceIdentifiers = _waitingResourceIdentifiersByEntityName[entityName] ?: [NSMutableSet new];
    [waitingResourceIdentifiers addObject:resourceIdentifier];
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
    fetchRequest.includesSubentities = NO;
    fetchRequest.returnsObjectsAsFaults = NO;
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"%K IN %@", _resourceIdentifierKey, waitingResourceIdentifiers];
        
    NSArray *results = [_managedObjectContext executeFetchRequest:fetchRequest error:outError];
    if ( ! results ) {
        return nil;
    }
        
    for ( NSManagedObject *result in results )
    {
        NSString *resourceIdentifier = [result valueForKeyPath:_resourceIdentifierKey];
        if ( ! resourceIdentifier ) {
            continue;
        }
        
        NSManagedObjectID *objectID = result.objectID;
        NSString *path = [self pathForEntityName:entityName resourceIdentifier:resourceIdentifier];
        _objectIDsByPath[path] = objectID;
        _resourceIdentifiersByObjectID[objectID] = resourceIdentifier;
    }
    
    for ( id resourceIdentifier in waitingResourceIdentifiers )
    {
        NSString *path = [self pathForEntityName:entityName resourceIdentifier:resourceIdentifier];
        if ( ! _objectIDsByPath[path] ) {
            _objectIDsByPath[path] = [NSNull null];
        }
    }
    
    [waitingResourceIdentifiers removeAllObjects];
    
    NSString *path = [self pathForEntityName:entityName resourceIdentifier:resourceIdentifier];
    NSManagedObjectID *objectID = _objectIDsByPath[path];
    if ( objectID == (id) [NSNull null] ) {
        if ( outError ) {
            NSString *description = [NSString stringWithFormat:@"Cannot find object for entity \"%@\" and resource identifier \"%@\"",entityName, resourceIdentifier];
            *outError = [NSError errorWithDomain:kAFIncrementalBackingErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return nil;
    }
    return objectID;
}

#pragma mark - Access

- (NSManagedObjectID *)objectIDForEntityName:(NSString *)entityName resourceIdentifier:(NSString *)resourceIdentifier error:(NSError **)outError
{
    NSString *path = [self pathForEntityName:entityName resourceIdentifier:resourceIdentifier];
    NSManagedObjectID *objectID = _objectIDsByPath[path];
    if ( ! objectID ) {
        return [self fetchObjectIDForEntityName:entityName resourceIdentifier:resourceIdentifier error:outError];
    }
    return objectID != (id) [NSNull null] ? objectID : nil;
}

- (NSDictionary *)attributesForObjectWithID:(NSManagedObjectID *)objectID
{
    NSManagedObject *object = [_managedObjectContext objectWithID:objectID];
    return [object dictionaryWithValuesForKeys:objectID.entity.attributesByName.allKeys];
}

- (NSString *)resourceIdentifierForObjectWithID:(NSManagedObjectID *)objectID
{
    return _resourceIdentifiersByObjectID[objectID] ?: [[_managedObjectContext objectWithID:objectID] valueForKeyPath:_resourceIdentifierKey];
}

- (NSArray *)objectIDsForRelationshipName:(NSString *)relationshipName forObjectWithID:(NSManagedObjectID *)objectID
{
    NSManagedObject *object = [_managedObjectContext objectWithID:objectID];
    NSRelationshipDescription *relationship = objectID.entity.relationshipsByName[relationshipName];
    id relationshipObject = [object valueForKeyPath:relationship.name];
    
    if ( relationship.isToMany ) {
        NSMutableArray *objectIDs = [NSMutableArray arrayWithCapacity:[relationshipObject count]];
        for ( NSManagedObject *relationshipSubObject in relationshipObject ) {
            NSManagedObjectID *subObjectID = relationshipSubObject.objectID;
            [objectIDs addObject:subObjectID];
        }
        return objectIDs;
    }
    else {
        NSManagedObjectID *objectID = [relationshipObject objectID];
        return objectID ? @[objectID] : nil;
    }
}

- (NSEntityDescription *)entityForName:(NSString *)entityName;
{
    return [NSEntityDescription entityForName:entityName inManagedObjectContext:_managedObjectContext];
}

#pragma mark - Editing

- (void)deleteObjectWithID:(NSManagedObjectID *)objectID
{
    NSManagedObject *object = [_managedObjectContext objectWithID:objectID];
    [_managedObjectContext deleteObject:object];
    NSString *resourceIdentifier = _resourceIdentifiersByObjectID[objectID];
    if ( resourceIdentifier ) {
        NSString *path = [self pathForEntityName:objectID.entity.name resourceIdentifier:resourceIdentifier];
        [_resourceIdentifiersByObjectID removeObjectForKey:objectID];
        [_objectIDsByPath removeObjectForKey:path];
    }
}

- (void)updateObjectWithID:(NSManagedObjectID *)objectID withAttributes:(NSDictionary *)attributes
{
    NSManagedObject *object = [_managedObjectContext objectWithID:objectID];
    [object setValuesForKeysWithDictionary:attributes];
}

- (void)updateObjectWithID:(NSManagedObjectID *)objectID withObjectIDs:(NSArray *)objectIDs forRelationshipName:(NSString *)relationshipName
{
    NSManagedObject *object = [_managedObjectContext objectWithID:objectID];
    NSRelationshipDescription *relationship = objectID.entity.relationshipsByName[relationshipName];
        
    if ( relationship.isToMany )
    {
        id relationshipObjects = nil;
        if ( relationship.isOrdered ) {
            relationshipObjects = [NSMutableOrderedSet orderedSetWithCapacity:objectIDs.count];
        } else {
            relationshipObjects = [NSMutableSet setWithCapacity:objectIDs.count];
        }
        
        for ( NSManagedObjectID *relationshipObjectID in objectIDs )
        {
            NSManagedObject *relationshipObject = [_managedObjectContext objectWithID:relationshipObjectID];
            [relationshipObjects addObject:relationshipObject];
        }
        [object setValue:relationshipObjects forKey:relationshipName];
    }
    else
    {
        NSManagedObjectID *relationshipObjectID = objectIDs.count ? objectIDs[0] : nil;
        NSManagedObject *relationshipObject = relationshipObjectID ? [_managedObjectContext objectWithID:relationshipObjectID] : nil;
        [object setValue:relationshipObject forKey:relationshipName];
    }
}

- (NSManagedObjectID *)objectIDForInsertedObjectForEntityName:(NSString *)entityName resourceIdentifier:(NSString *)resourceIdentifier
{
    NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entityName inManagedObjectContext:_managedObjectContext];
    NSManagedObjectID *objectID = object.objectID;
    
    if ( resourceIdentifier )
    {
        NSString *path = [self pathForEntityName:entityName resourceIdentifier:resourceIdentifier];
        _resourceIdentifiersByObjectID[objectID] = resourceIdentifier;
        _objectIDsByPath[path] = objectID;
    }
    return objectID;
}

- (BOOL)save:(NSError **)outError
{
    NSMutableArray *objects = [NSMutableArray new];
    NSMutableArray *paths = [NSMutableArray new];
    NSMutableArray *temporaryObjectIDs = [NSMutableArray new];
    NSMutableArray *resourceIdentifiers = [NSMutableArray new];
    
    for ( NSManagedObject *object in _managedObjectContext.insertedObjects )
    {
        NSManagedObjectID *objectID = object.objectID;
        if ( ! objectID.isTemporaryID ) {
            // Who did obtain a permanent ID?!
            continue;
        }
        
        NSString *resourceIdentifier = [self resourceIdentifierForObjectWithID:objectID];
        if ( ! resourceIdentifier ) {
            continue;
        }
        
        NSString *path = [self pathForEntityName:objectID.entity.name resourceIdentifier:resourceIdentifier];
        [paths addObject:path];
        [temporaryObjectIDs addObject:objectID];
        [objects addObject:object];
        [resourceIdentifiers addObject:resourceIdentifier];
    }
    
    if ( ! [_managedObjectContext obtainPermanentIDsForObjects:objects error:outError] ) {
        return NO;
    }
    NSArray *permanentObjectIDs = [objects valueForKeyPath:@"objectID"];
    
    [_objectIDsByPath addEntriesFromDictionary:[NSDictionary dictionaryWithObjects:permanentObjectIDs forKeys:paths]];
    [_resourceIdentifiersByObjectID removeObjectsForKeys:temporaryObjectIDs];
    [_resourceIdentifiersByObjectID addEntriesFromDictionary:[NSDictionary dictionaryWithObjects:resourceIdentifiers forKeys:permanentObjectIDs]];
    
    return [_managedObjectContext save:outError];
}

- (void)performBlockAndWait:(void (^)(void))block
{
    [_managedObjectContext performBlockAndWait:block];
}

#pragma mark - Path

- (NSString *)pathForEntityName:(NSString *)entityName resourceIdentifier:(id)resourceIdentifier
{
    return [entityName stringByAppendingPathComponent:resourceIdentifier];
}

@end
