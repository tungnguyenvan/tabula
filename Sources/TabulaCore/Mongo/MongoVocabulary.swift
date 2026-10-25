import Foundation

/// Names the MongoDB shell knows, for highlighting and completion.
public enum MongoVocabulary {
    public static let statementStarts = ["db", "show", "use"]
    public static let showTargets = ["dbs", "collections", "users", "roles"]

    public static let databaseMethods = [
        "getCollection", "getSiblingDB", "getCollectionNames", "getCollectionInfos", "createCollection", "createView",
        "runCommand", "adminCommand", "aggregate", "stats", "serverStatus", "version", "getName", "hostInfo", "currentOp",
        "getUsers", "getRoles", "dropDatabase", "hello", "listCommands", "getProfilingStatus",
    ]

    public static let collectionMethods = [
        "find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "distinct",
        "insertOne", "insertMany", "updateOne", "updateMany", "replaceOne", "deleteOne", "deleteMany",
        "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete",
        "createIndex", "createIndexes", "dropIndex", "dropIndexes", "getIndexes", "drop", "renameCollection", "stats",
    ]

    public static let cursorMethods = [
        "sort", "limit", "skip", "projection", "count", "explain", "hint", "collation", "maxTimeMS", "batchSize",
        "comment", "allowDiskUse", "toArray", "pretty",
    ]

    public static let constructors = [
        "ObjectId", "ISODate", "NumberLong", "NumberInt", "NumberDecimal", "UUID", "BinData", "Timestamp", "RegExp",
        "MinKey", "MaxKey", "Date", "Long", "Int32", "Double", "Decimal128", "Code",
    ]

    public static let literals = ["true", "false", "null", "undefined", "new"]

    /// Query, update and aggregation operators people reach for most.
    public static let operators = [
        // Query
        "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$nin", "$and", "$or", "$nor", "$not", "$exists", "$type",
        "$regex", "$options", "$elemMatch", "$size", "$all", "$expr", "$text", "$search", "$near", "$geoWithin", "$mod",
        // Update
        "$set", "$unset", "$inc", "$mul", "$rename", "$min", "$max", "$currentDate", "$setOnInsert", "$push", "$pull",
        "$addToSet", "$pop", "$pullAll", "$each", "$position", "$slice", "$sort",
        // Aggregation stages
        "$match", "$group", "$project", "$sort", "$limit", "$skip", "$unwind", "$lookup", "$addFields", "$count",
        "$facet", "$bucket", "$sortByCount", "$replaceRoot", "$replaceWith", "$sample", "$out", "$merge", "$unionWith",
        "$graphLookup", "$densify", "$fill", "$setWindowFields",
        // Expressions and accumulators
        "$sum", "$avg", "$first", "$last", "$push", "$cond", "$ifNull", "$concat", "$toString", "$toInt", "$toDate",
        "$dateToString", "$year", "$month", "$dayOfMonth", "$size", "$arrayElemAt", "$filter", "$map", "$reduce",
        "$switch", "$substr", "$toLower", "$toUpper", "$split", "$round", "$multiply", "$divide", "$add", "$subtract",
    ].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

    /// Words the editor colors: shell methods, constructors and literals (operators are colored by their `$`).
    public static let highlighted: Set<String> = Set(statementStarts + databaseMethods + collectionMethods + cursorMethods
        + constructors + literals)
}
