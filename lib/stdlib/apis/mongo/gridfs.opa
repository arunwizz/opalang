/*
    Copyright © 2011, 2012 MLstate

    This file is part of Opa.

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

abstract
type GridFS.t = {
    Mongo.db    db,
    string      namespace,
    string      ns,
    string      key,
}

private
type GridFS.file_stored = {
    Mongo.reply reply,
    GridFS.t    grid,
}

private
type GridFS.file_local = iter(binary)

abstract
type GridFS.file('a) = {
    'a metadata,
    {GridFS.file_stored stored} or {GridFS.file_local local} file,
}

private
type GridFS.chunk = {
    Bson.value files_id,
    int n,
    binary data,
}

type GridFS.conf('a) = {
    'a -> Bson.document
      serialize,
    Bson.document -> option('a)
      unserialize,
    int
      chunk_size,
}

/**
 * GridFS is a storage for large files in MongoDb.
 *
 * @destination public
 * @stabilization work in progress
 **/
module GridFS{

    private
    upsert_flags = Bitwise.lor(0, MongoCommon.UpsertBit)

    private
    function updateerr(Mongo.db db, flags, ns, selector, update, upsert){
        reply = MongoDriver.updatee(db, flags, ns, selector, update)
        match(reply){
        case {none} : {failure : {Error : "Network error"}}
        case {some : reply} :
            match(MongoCommon.reply_document(reply, 0)){
            case {none} : {failure : {Error : "Protocol Error (1)"}}
            case {some : doc} :
                match(Bson.find_float(doc, "ok")){
                case {none} : {failure : {Error : "Protocol Error (2)"}}
                case {some : ok} :
                    if(ok != 1.0){
                        {failure : {Error : "MongoDb GetLastError : {doc}" }}
                    } else {
                        match(Bson.find_element(doc, "err")){
                        case {none} : {success}
                        case {some : {value : {String : str} ...}} :
                            {failure : {Error : "DbGen/Mongo: {str}"}}
                        case {some : {value : {Null} ...}} :
                            if(not(upsert)){
                                match(Bson.find_bool(doc, "updatedExisting")){
                                case {some:{true}} : {failure : {Error : "Update error"}}
                                case {some:{false}} : {success}
                                case {none} : {failure : {Error : "Protocol Error (4)"}}
                                }
                            } else {
                                {success};
                            }
                        case {some : err} :
                            {failure : {Error : "DbGen/Mongo: Protocol Error (3) {err}"}}
                        }
                    }
                }
            }
        }
    }

    private
    module Chunk{

        function chunks_selector(id){
            [{name : "files_id", value : id}]
        }

        function chunks_ns(grid){
            "{grid.namespace}.chunks"
        }

        function write(GridFS.t grid,  Bson.value id, GridFS.chunk chunk){
            updateerr(
                grid.db, upsert_flags, chunks_ns(grid), [
                    {name:"files_id", value:id},
                    {name:"n", value:{Int64:chunk.n}},
                ], [
                    {name:"files_id", value:chunk.files_id},
                    {name:"n", value:{Int64:chunk.n}},
                    {name:"data", value:{Binary:chunk.data}}
                ], true
            )
        }

        function writes(GridFS.t grid, Bson.value id, GridFS.file file, options){
            ~{n, next} = Iter.fold(
                function(bin, ~{n, next}){
                    Log.notice("Fold", "{n}")
                    blen = Binary.length(bin)
                    nlen = Binary.length(next)
                    if(blen + nlen < options.chunk_size){
                        Binary.add_binary(next, bin)
                        ~{n, next}
                    } else {
                        recursive function aux(n, start, next){
                            nlen = Binary.length(next)
                            split = min(blen, options.chunk_size + start)
                            Log.notice("GridFS", "Add {nlen} {blen} {start} {split}")
                            Binary.add_binary(next, Binary.get_binary(bin, start, split - start))
                            //TODO - Error management
                            _ = write(grid, id, {~n, data:next, files_id:options.files_id})
                            if(split + options.chunk_size >= blen){
                                {n:n+1, next:Binary.get_binary(bin, split, blen - split)}
                            } else {
                                aux(n+1, split, Binary.create(options.chunk_size))
                            }
                        }
                        aux(n, 0, next)
                    }
                },
                GridFS.to_iterator(file),
                {n:0, next:Binary.create(options.chunk_size)}
            )
            write(grid, id, {~n, data:next, files_id:options.files_id})
        }

        function read(GridFS.t grid, Bson.value id){
            query = chunks_selector(id)
            selector = [
                {name : "$query", value : {Document : query}},
                {name : "$orderby", value : {Document : [
                    {name:"n", value:{Int32 : 1}}
                ]}},
            ]
            match(MongoDriver.query(grid.db, 0, chunks_ns(grid), 0, 0, selector, none)){
            case {none} : {failure : {Error : "Connection error"}}
            case {some:reply} : {success : GridFS.file_stored ~{reply, grid}}
            }
        }

        function delete(GridFS.t grid, Bson.value id){
            MongoDriver.deletee(grid.db, 0, chunks_ns(grid), chunks_selector(id))
        }
    }

    private
    module File{

        function files_selector(id){
            [{name:"_id", value:id}]
        }

        function files_ns(grid){
            "{grid.namespace}.files"
        }

        function build(GridFS.t grid, Bson.value id, options){
            match(MongoCommands.run_command_ll(
                grid.db, grid.db.name, [
                    {name:"filemd5", value:id},
                    {name:"root", value:{String:grid.ns}}
                ])){
            case {success : bson} :
                match(Bson.find_element(bson, "md5")){
                case {some : md5} :
                    {success : (Bson.document [
                        {name:"_id", value:id},
                        md5
                    ] ++ options.metadata) }
                case _ : {failure : {Error : "Unexpected result of 'filemd5' commands: {bson}"}}
                }
            case {failure:_} as e -> e
            }
        }

        function save(GridFS.t grid, Bson.value id, options){
            match(build(grid, id, options)){
            case {failure:_} as e : e
            case {success:bson} :
                selector = [
                    {name : "_id", value : id}
                ]
                updateerr(grid.db, upsert_flags, files_ns(grid), selector, bson, true)
            }
        }

        function read(GridFS.t grid, Bson.value id, filter){
            match(query(grid, files_selector(id), filter, 0, 1)){
            case {failure:_} as e : e
            case {success:reply} :
                match(MongoCommon.reply_document(reply, 0)){
                case {none} : {failure : {Error : "No document"}}
                case {some:document} : {success : document}
                }
            }
        }

        function delete(GridFS.t grid, Bson.value id){
            MongoDriver.deletee(grid.db, 0, files_ns(grid), files_selector(id))
        }

        function query(GridFS.t grid, query, filter, skip, limit){
            match(MongoDriver.query(grid.db, 0, files_ns(grid), skip, limit, query, filter)){
            case {none} : {failure : {Error : "Connection error"}}
            case {some:reply} : {success:reply}
            }
        }
    }

    /**
     * Create a Grid.
     * @param db The databases which host the grid.
     * @param namespace The namespace where the grid is stored
     */
    function GridFS.t open(Mongo.db db, string namespace){
        ns = namespace
        namespace = "{db.name}.{namespace}"
        grid = ~{db, namespace, ns, key:"_id"}
        result = MongoDriver.create_index(db, Chunk.chunks_ns(grid), [
            {name:"files_id", value:{Int32:1}},
            {name:"n", value:{Int32:1}},
        ], Bitwise.lor(0, MongoCommon.UniqueBit))
        if(result){
            Log.notice("GridFS", "Indexes was successfully created")
        } else {
            Log.error("GridFS", "Cannot create indexes")
        }
        grid
    }

    private
    Document = Driver({
        function serialize(doc){doc},
        function unserialize(doc){some(doc)},
        chunk_size : 256000,
    })

    /**
     * Create a file from a binary iterator.
     * @param iterator A binary iterator which returns the file content
     */
    function create(iter(binary) iterator){
        Void.create(void, iterator)
    }

    /**
     * Write [data] to the [grid].
     * @param grid The grid where the file is stored
     * @param data Content of the file
     * @param id The file identifier
     */
    write = Void.write

    /**
     * Get binary data stored to the [grid]
     * @param grid The grid where the file is stored
     * @param id The file identifier
     */
    read = Void.read

    /**
     * Delete from the [grid] the file identified by [id].
     * @param grid The grid where the file is stored
     * @param id The file identifier
     */
    function delete(GridFS.t grid, Bson.value id){
        _ = Chunk.delete(grid, id)
        _ = File.delete(grid, id)
        void
    }

    /**
     * Create a driver for specific metadata. A specific driver configuration for
     * a spedific type can be easily builded by coercing a call to
     * [GridFS.driver_conf]. As example for a type [t] write [GridFS.conf(t)
     * tconf = GridFS.driver_conf()].
     * @param conf The driver configuration
     * @return A specific GridFS driver
     */
    module Driver(GridFS.conf conf){

        private
        function get_metadata(doc){
            doc = List.filter(function(~{name, ...}){
                name != "_id" && name != "md5"
            }, doc)
            match(conf.unserialize(doc)){
            case {some:metadata} : {success : metadata}
            case {none} : {failure : {Error : "Metadata are corrupted"}}
            }
        }

        function write(GridFS.t grid, Bson.value id, GridFS.file('a) file){
            chunk_options = {chunk_size:conf.chunk_size, files_id:id}
            match(Chunk.writes(grid, id, file, chunk_options)){
            case {failure:_} as e : e
            case {success} :
                file_options = {chunk_size : conf.chunk_size,
                                length : 0,
                                metadata : conf.serialize(file.metadata)}
                File.save(grid, id, file_options)
            }
        }

        function outcome(GridFS.file, _) read(GridFS.t grid, Bson.value id){
            match(Chunk.read(grid, id)){
            case {failure:_} as e : e
            case {success:stored} :
                match(File.read(grid, id, none)){
                case {failure:_} as e : e
                case {success:document} :
                    match(get_metadata(document)){
                    case {failure:_} as e : e
                    case {success:metadata} :
                        {success : {~metadata, file:~{stored}}}
                    }
                }
            }
        }

        function outcome(iter(GridFS.file), Mongo.failure) query(GridFS.t grid, query, filter, skip, limit){
            match(File.query(grid, query, filter, skip, limit)){
            case {failure:_} as e : e
            case {success:reply} :
                docs = MongoDriver.to_iterator(grid.db, File.files_ns(grid), reply)
                {success : Iter.map(function(doc){
                    match(Bson.find_value(doc, "_id")){
                    case {none} :
                        @fail("Can't find file identifier from document: {doc}")
                    case {some:id} :
                        match(Chunk.read(grid, id)){
                        case {failure:e} :
                            @fail("Can't find chunks of file: {id}\nfailure : {e}")
                        case {success:stored} :
                            match(get_metadata(doc)){
                            case {failure: e} : @fail("{e}")
                            case {success: metadata} :
                                GridFS.file {~metadata, file : ~{stored}}
                            }
                        }
                    }
                }, docs)}
            }
        }

        function GridFS.file create(metadata, iter(binary) iterator){
            ~{metadata, file : {local : iterator}}
        }
    }

    /**
     * Build a specific configuration for a GridFS driver. See [GridFS.Driver].
     */
    function GridFS.conf('a) driver_conf(){
        {serialize   : Bson.opa2doc,
         unserialize : Bson.doc2opa,
         chunk_size  : 256000}
    }

    /**
     * Returns a binary iterator from a gridfs file.
     * @param file A gridfs file
     * @return A binary iterator on the file content
     */
    function iter(binary) to_iterator(GridFS.file file){
        match(file.file){
        case ~{local ...} : local
        case {stored:~{grid, reply} ...} :
            docs = MongoDriver.to_iterator(grid.db, Chunk.chunks_ns(grid), reply)
            Iter.map(function(doc){
                match(Bson.find_value(doc, "data")){
                case {some : {Binary : bin}} : bin
                case _ : @fail("Unexpected error: bad formatted data")
                }
            }, docs)
        }
    }

    /**
     * Returns the binary content from a gridfs file.
     * @param file A gridfs file
     * @return The binary content of the file
     */
    function to_binary(GridFS.file file){
        bin = Binary.create(1024)
        Iter.iter(function(chunk){
            Binary.add_binary(bin, chunk)
        }, to_iterator(file))
        bin
    }


}
