// AFIncrementalBacking.h
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

#import <CoreData/CoreData.h>

@interface AFIncrementalBacking : NSObject

@property (nonatomic, readonly) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, readonly) NSString *resourceIdentifierKey;
@property (nonatomic, assign) id delegate;

- (id)initWithManagedPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)persistentStoreCoordinator
                          resourceIdentifierKey:(NSString *)resourceIdentifierKey;

- (void)prefetchObjectForEntityName:(NSString *)entityName resourceIdentifier:(NSString *)resourceIdentifier;

- (NSArray *)executeFetchRequest:(NSFetchRequest *)request
                           error:(NSError **)outError
               usingInstantiator:(NSManagedObject *(^)(NSManagedObjectID *objectID, NSError **outError))instantiator;

- (NSManagedObjectID *)objectIDForEntityName:(NSString *)entityName resourceIdentifier:(NSString *)resourceIdentifier error:(NSError **)outError;
- (NSDictionary *)attributesForObjectWithID:(NSManagedObjectID *)objectID;
- (NSString *)resourceIdentifierForObjectWithID:(NSManagedObjectID *)objectID;
- (NSArray *)objectIDsForRelationshipName:(NSString *)relationshipName forObjectWithID:(NSManagedObjectID *)objectID;
- (NSEntityDescription *)entityForName:(NSString *)entityName;

- (void)deleteObjectWithID:(NSManagedObjectID *)objectID;
- (void)updateObjectWithID:(NSManagedObjectID *)objectID withAttributes:(NSDictionary *)attributes;
- (void)updateObjectWithID:(NSManagedObjectID *)objectID withObjectIDs:(NSArray *)objectIDs forRelationshipName:(NSString *)relationshipName;
- (NSManagedObjectID *)objectIDForInsertedObjectForEntityName:(NSString *)entityName resourceIdentifier:(NSString *)resourceIdentifier;
- (BOOL)save:(NSError **)outError;

- (void)performBlockAndWait:(void (^)(void))block;

@end
