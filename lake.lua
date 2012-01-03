#!/usr/bin/env lua
-- Lake - a build framework in Lua
-- Freely distributable for any purpose, as long as copyright notice is retained. (X11/MIT)
-- (And remember my dog did not eat your homework)
-- Steve Donovan, 2007-2010

local usage = [[
Lake version 1.2  A Lua-based Build Engine
  lake <flags> <assigments> <target(s)>
  -Flags:
    -v verbose
    -n don't synthesize target
    -d initial directory
    -t test (show but don't execute commands)
    -s strict compile
    -g debug build
    -f FILE read a named lakefile
    -e EXPR evaluate an expression
    -l FILE build a shared library/DLL
    -p FILE build a program
    -w write out unsatisfied needs to lakeconfig.lua
    -lua FILE build a Lua binary extension
  -assigmnents: arguments of the form VAR=STRING assign the string
         to the global VAR
  -target(s): any targets of the lakefile; if a file with a recognized
          extension, build and run, passing any remaining arguments.

]]

local lfs = require 'lfs'
local append = table.insert
local verbose = false
local specific_targets = {}
local nbuild = 0
local all_targets_list = {}
local attributes = lfs.attributes
local env = os.getenv
local concat = table.concat

local TMPSPEC = '_t_.spec'
local specfile
local outspec
local lakefile
local change_dir,finalize,exists

TESTING = false

DIRSEP = package.config:sub(1,1)
WINDOWS = DIRSEP == '\\'

---some useful library functions for manipulating file paths, lists, etc.
-- search for '--end_of_libs' to skip to the Meat of the Matter!

function warning(reason,...)
    local str = reason:format(...)
    io.stderr:write('lake: ',str,'\n')
end

function quit(reason,...)
    warning(reason,...)
    finalize()
    os.exit(1)
end

function choose(cond,v1,v2)
    if type(cond) == 'string' then
        cond = cond~='0' and cond~='false'
    end
    if cond then return v1 else return v2 end
end

function pick(a,b)
    if a ~= nil then return a else return b end
end

file = {ext='*'}
COPY = choose(WINDOWS,'copy','cp')
file.compile = '$(COPY) $(DEPENDS) $(TARGET)'

function file.copy(src,dest)
    local inf,err = io.open(src,'r')
    if err then quit(err) end
    local outf,err = io.open(dest,'w')
    if err then quit(err) end
    outf:write(inf:read('*a'))
    outf:close()
    inf:close()
end

function file.write (name,text)
    local outf,err = io.open(name,'w')
    if not outf then quit('%s',err) end
    outf:write(text);
    outf:close()
    return true
end

function file.read (name)
    local inf,err = io.open(name,'r')
    if not inf then return false,err end
    local res = inf:read('*a')
    inf:close()
    return res
end

function file.touch(name)
    if not path.exists(name) then
        return file.write(name,'dummy')
    else
        return lfs.touch(name)
    end
end

function file.temp ()
    local res = os.tmpname()
    if WINDOWS then -- note this necessary workaround for Windows
        res = env 'TMP'..res
    end
    return res
end

function file.temp_copy (s)
    local res = file.temp()
    local ok,err = file.write(res,s)
    if not ok then return nil,err end
    return res
end

function file.find(...)
    local t_remove = table.remove
    local args = {...}
    if #args == 1 then return exists(args[1]) end
    for i = 1,#args do
        if type(args[i]) == 'string' then args[i] = {args[i]} end
    end
    local p,q = args[1],args[2]
    local pres = {}
    for _,pi in ipairs(p) do
        for _,qi in ipairs(q) do
            local P
            if qi:find '^%.' then  P = pi..qi
            else  P = pi..DIRSEP..qi
            end
            P = exists(P)
            if P then append(pres,P) end
        end
    end
    if #pres == 0 then return pres end
    local a1= t_remove(args,1)
    local a2 = t_remove(args,1)
    if #args > 0 then
        return file.find(pres,unpack(args))
    else
        return pres,a1,a2
    end
end

find = {}

if WINDOWS then
    SYS_PREFIX = ''
else
    SYS_PREFIX = {'/usr','/usr/share','/usr/local'}
end

function find.include_path(candidates)
    local res = file.find(SYS_PREFIX,'include',candidates)
    if #res == 0 then return nil end -- can't find it!
    res = res[1] -- _might_ be other instances, probably pathological?
    if type(candidates)=='string' then candidates = {candidates} end
    for _,c in ipairs(candidates) do
        local i1,i2 = res:find(C..'$')
    end
    return res
end

function file.time(fname)
    local time,err = attributes(fname,'modification')
    if time then
        return time
    else
        return -1
    end
end

local filetime = file.time

local function at(s,i)
    return s:sub(i,i)
end

path = {}
local join

function exists(path,fname)
    if fname then fname = join(path,fname) else fname = path end
    if attributes(fname) ~= nil then
        return fname
    end
end
path.exists = exists

-- is @path a directory?
local function isdir(path)
    if path:match '/$' then path = path:sub(1,-2) end
    return attributes(path,'mode') == 'directory'
end
path.isdir = isdir

-- is @path a file?
local function isfile(path)
    return attributes(path,'mode') == 'file'
end
path.isfile = isfile

-- is this an absolute @path?
local function isabs(path)
    if WINDOWS then return path:find '^"*%a:' ~= nil
    else return path:find '^/' ~= nil
    end
end
path.isabs = isabs

local function quote_if_necessary (file)
    if file:find '%s' then
        file = '"'..file..'"'
    end
    return file
end

-- this is used for building up strings when the initial value might be nil
--  s = concat_str(s,"hello")
local function concat_str (v,u,no_quote)
    if not no_quote then u = quote_if_necessary(u) end
    if type(v) == 'table' then v = table.concat(v,' ') end
    return (v or '')..' '..u
end

local get_files
function get_files (files,path,pat,recurse)
    for f in lfs.dir(path) do
        if f ~= '.' and f ~= '..' then
            local file = f
            if path ~= '.' then file  = join(path,file) end
            if recurse and isdir(file) then
                get_files(files,file,pat,recurse)
            elseif f:find(pat) then
                append(files,file)
            end
        end
    end
end
path.get_files = get_files

local function get_directories (dir)
    local res = {}
    for f in lfs.dir(dir) do
        if f ~= '.' and f ~= '..' then
            local path = join(dir,f)
            if isdir(path) then append(res,path) end
        end
    end
    return res
end
path.get_directories = get_directories

local splitpath

local function files_from_mask (mask,recurse)
    local path,pat = splitpath(mask)
    if not pat:find('%*') then return nil end
    local files = {}
    if path=='' then path = '.' end
    -- turn shell-style wildcard into Lua regexp
    pat = pat:gsub('%.','%%.'):gsub('%*','.*')..'$'
    get_files(files,path,pat,recurse)
    return files
end
path.files_from_mask = files_from_mask

local list_

local function mask(mask)
    return list_(files_from_mask(mask))
end
path.mask = mask

local function is_mask (pat)
    return pat:find ('*',1,true)
end
path.is_mask = is_mask

local function dirs(dir)
    return list_(get_directories(dir))
end
path.dirs = dirs

utils = {}
local function split(s,re)
    local i1 = 1
    local ls = {}
    while true do
        local i2,i3 = s:find(re,i1)
        if not i2 then
            append(ls,s:sub(i1))
            return ls
        end
        append(ls,s:sub(i1,i2-1))
        i1 = i3+1
    end
end
utils.split = split

local function split2(s,delim)
  return s:match('([^'..delim..']+)'..delim..'(.*)')
end

-- given a path @path, return the directory part and a file part.
-- if there's no directory part, the first value will be empty
function splitpath(path)
    local i = #path
    local ch = at(path,i)
    while i > 0 and ch ~= '/' and ch ~= '\\' do
        i = i - 1
        ch = at(path,i)
    end
    if i == 0 then
        return '',path
    else
        return path:sub(1,i-1), path:sub(i+1)
    end
end
path.splitpath = splitpath

-- given a path @path, return the root part and the extension part
-- if there's no extension part, the second value will be empty
local function splitext(path)
    local i = #path
    local ch = at(path,i)
    while i > 0 and ch ~= '.' do
        if ch == '/' or ch == '\\' then
            return path,''
        end
        i = i - 1
        ch = at(path,i)
    end
    if i == 0 then
        return path,''
    else
        return path:sub(1,i-1),path:sub(i)
    end
end
path.splitext = splitext

-- return the directory part of @path
local function dirname(path)
    local p1,p2 = splitpath(path)
    return p1
end
path.dirname = dirname

-- return the file part of @path
local function basename(path)
    local p1,p2 = splitpath(path)
    return p2
end
path.basename = basename

local function extension_of(path)
    local p1,p2 = splitext(path)
    return p2
end
path.extension_of = extension_of

local function expanduser(path)
    if path:sub(1,1) == '~' then
        local home = env 'HOME'
        if not home then -- has to be Windows
            home = env 'USERPROFILE' or (env 'HOMEDRIVE' .. env 'HOMEPATH')
        end
        return home..path:sub(2)
    else
        return path
    end
end
path.expanduser = expanduser


local function replace_extension (path,ext)
    local p1,p2 = splitext(path)
    return p1..ext
end
path.replace_extension = replace_extension

-- return the path resulting from combining @p1,@p2 and optionally @p3 (an extension);
-- if @p2 is already an absolute path, then it returns @p2
function join(p1,p2,p3)
    if p3 then p2 = p2 .. p3 end -- extension part
    if isabs(p2) then return p2 end
    local endc = at(p1,#p1)
    if endc ~= '/' and endc ~= '\\' then
        p1 = p1..DIRSEP
    end
    return p1..p2
end
path.join = join

-- this expands any $(VAR) occurances in @s (where VAR is a global varialable).
-- If VAR is not present, then the expansion is just the empty string, unless
-- it is on the @exclude list, where it remains unchanged, ready for further
-- expansion at a later stage.
local function subst(str,exclude,T)
    local count
    T = T or _G
    repeat
        local excluded = 0
        str, count = str:gsub('%$%(([%w,_]+)%)',function (f)
            if exclude and exclude[f] then
                excluded = excluded + 1
                return '$('..f..')'
            else
                local s = T[f]
                if not s then return ''
                else return s end
            end
        end)
    until count == 0 or exclude
    return str
end
utils.subst = subst

function utils.substitute (str,T) return subst(str,nil,T) end

-- this executes a shell command @cmd, which may contain % string.format specifiers,
-- in which case any extra arguments are used. It may contain ${VAR} which will
-- be substituted
local function shell_nl(cmd,...)
    cmd = subst(cmd):format(...)
    local inf = io.popen(cmd..' 2>&1','r')
    if not inf then return '' end
    local res = inf:read('*a')
    inf:close()
    return res
end
utils.shell_nl = shell_nl

-- a convenient function which gets rid of the trailing line-feed from shell_nl()
local function shell(cmd,...)
    return (shell_nl(cmd,...):gsub('\n$',''))
end
utils.shell = shell

-- splits a list separated by ' ' or ','. Note that some hackery is needed
-- to preserve double quoted items.

local marker = string.char(4)
local function hide_spaces(q) return q:gsub(' ',marker) end

function utils.split_list(s)
    s = s:gsub('^%s+',''):gsub('%s+$','') -- trim the string
    s = s:gsub('"[^"]+"',hide_spaces)
    local i1 = 1
    local ls = {}
    local function append_item (item)
        item = item:gsub('\\ ',' ')
        append(ls,item)
    end
    while true do
        local i2,i3 = s:find('[^\\][%s,]+',i1)
        if not i2 then
            append_item(s:sub(i1))
            break
        end
        append_item(s:sub(i1,i2))
        i1 = i3+1
    end
    for i = 1,#ls do
        if ls[i]:find(marker) then
            ls[i] = ls[i]:gsub(marker,' ') --:gsub('"','')
        end
    end
    return ls
end
local split_list = utils.split_list
local expand_args

function utils.forall(ls,action)
    ls = expand_args(ls)
    for i,v in ipairs(ls) do
        action(v)
    end
end
local forall = utils.forall

-- useful global function which deletes a list of files @items
function utils.remove(items)
    if type(items) == 'string' then
        items = split_list(items)
    end
    forall(items,function(f)
        if os.remove(f) then
            print ('removing',f)
        end
    end)
end
local remove = utils.remove

function utils.remove_files (mask)
    local cmd
    if WINDOWS then
        cmd = 'del '..mask
    else
        cmd = 'rm '..mask
    end
    exec(cmd)
end
local remove_files = utils.remove_files

function is_simple_list (t)
    return type(t) == 'table' and t[1]
end

list = {}

local append_list,copy_list,copy_table,append_table,erase_list,concat_list,index_list,find_list

function append_list(l1,l2)
    for i,v in ipairs(l2) do
        append(l1,v)
    end
    return l1
end
list.extend = append_list

function copy_list (l1)
    return append_list({},l1)
end
list.copy = copy_list

function copy_table (t)
    local res = {}
    for k,v in pairs(t) do
        res[k] = v
    end
    return res
end
table.copy = copy_table

function append_table(l1,l2)
    if not l2 then return end
    for k,v in pairs(l2) do
        l1[k] = v
    end
    return l1
end
table.update = append_table

function table.set(ls)
    local res = {}
    for item in list_(ls) do
        res[item] = true
    end
    return res
end

function erase_list(l1,l2)
    for i,v in ipairs(l2) do
        local idx = index_list(l1,v)
        if idx then
            table.remove(l1,idx)
        end
    end
end
list.erase = erase_list

function concat_list(pre,ls,sep)
    local res = ''
    for i,v in ipairs(ls) do
        if v ~= '' then
            res = res..pre..v..sep
        end
    end
    return res
end
list.concat = concat_list

function index_list(ls,val)
    for i,v in ipairs(ls) do
        if v == val then return i end
    end
end
list.index = index_list

function find_list(ls,field,value)
    for i,v in ipairs(ls) do
        if v[field] == value then
            return v
        end
    end
end
list.find = find_list

-- used to iterate over a list, which may be given as a string:
--  for val in list(ls) do ... end
--  for val in list 'one two three' do .. end
function list_(ls)
    if type(ls) == 'string' then
        ls = split_list(ls)
    end
    local n = #ls
    local i = 0
    return function()
        i = i + 1
        if i > n then return nil end
        return ls[i]
    end
end

function utils.make_callable (obj,fun)
    local mt = getmetatable(obj)
    if not mt then
        mt = {}
        setmetatable(obj,mt)
    end
     mt.__call = function(obj,...) return fun(...) end
    return mt
end

utils.make_callable(list,list_)

function append_unique(ls,val)
    if not index_list(ls,val) then
        return append(ls,val)
    end
end
list.append_unique = append_unique

function column_list(ls,f)
    local res = {}
    for i,t in ipairs(ls) do
        append(res,t[f])
    end
    return res
end
list.column = column_list

local function parm_list_concat(ls,istart)
    local s = ' '
    istart = istart or 1
    for i = istart,#ls do
        local a = ls[i]
        if a:find(' ') then a = '"'..a..'"' end
        s = s..a..' '
    end
    return s
end

-- readlines(f) works like f:lines(), except it will handle lines separated by '\'
function utils.readlines(f)
    return function()
        local line = ''
        repeat
            local l = f:read()
            if not l then return nil end
            local last = l:sub(-1,-1)
            if last == '\\' then
                l = l:sub(1,-2)
            end
            line = line..l
        until last ~= '\\'
        return line
    end
end
local readlines = utils.readlines

-- for debug purposes: dump out a table
function dump(ls,msg)
    print ('<<<',msg)
    if type(ls) == 'table' then
        for i,v in pairs(ls) do
            print(i,v)
        end
    else
        print(ls)
    end
    print '>>'
end

function utils.which (prog)
    if isabs(prog) then return prog end
    if WINDOWS  then -- no 'which' commmand, so do it directly
        if extension_of(prog) == '' then prog = prog..'.exe' end
        local path = split(env 'PATH',';')
        for dir in list_(path) do
            local file = exists(dir,prog)
            if file then return file end
        end
        return false
    else
        local res = shell('which %s 2> /dev/null',prog)
        if res == '' then return false end
        return res
    end
end

--end_of_libs---------------------------------------------

local interpreters = {
    ['.lua'] = 'lua', ['.py'] = 'python',
}

local check_options

if WINDOWS then
    LOCAL_EXEC = ''
    EXE_EXT = '.exe'
    DLL_EXT = '.dll'
else
    LOCAL_EXEC = './'
    EXE_EXT = ''
    DLL_EXT = '.so'
end


LIBS = ''
CFLAGS = ''


local function inherits_from (c)
    local mt = {__index = c}
    return function(t)
        return setmetatable(t,mt)
    end
end

local function appender ()
    local t = {}
    utils.make_callable(t,function(a)
        check_options(a)
        append_table(t,a)
    end)
    return t
end


lake = {}

c = {ext='.c'}
local CI = inherits_from(c)
c.defaults = appender()

-- these chaps inherit from C lang for many of their fields
cpp = CI{ext='.cpp'}
f = CI{ext='.f'}
c99 = CI{ext='.c'}

cpp.defaults = appender()
f.defaults = appender()
c99.defaults = appender()

wresource = {ext='.rc'}


local extensions = {
    ['.c'] = c, ['.cpp'] = cpp, ['.cxx'] = cpp, ['.C'] = cpp,
    ['.f'] = f, ['.for'] = f, ['.f90'] = f,
}

local deps_args

function lake.register(lang,extra)
    extensions[lang.ext] = lang
    if extra then
        for e in list_(deps_arg(extra)) do
            extensions[e] = lang
        end
    end
end

-- @doc any <var>=<value> pair means set the global variable <var> to the <value>, as a string.
function process_var_pair(a)
    local var,val = split2(a,'=')
    if var then
        _G[var] = val
        return true
    end
end

-- @doc dependencies are stored as lists, but if you go through deps_arg, then any string
-- delimited with ' ' or ',' will be converted into an appropriate list.
-- This function is guaranteed to return a plain list, and will wrap other objects like
-- targets and rules appropriately. Target lists are extracted.
function deps_arg(deps,base)
    local T = type(deps)
    if T=='table' and not is_simple_list(deps) then
        local tl = get_target_list(deps)
        if tl then
            return tl
        else
            return {deps}
        end
    end
    if T=='string' then
        deps = split_list(deps)
    elseif T~='table' then
        --quit("deps_arg must be passed a string or table; got "..T)
    end
    if base then
        for i = 1,#deps do
            deps[i] = join(base,deps[i])
        end
    end
    return deps
end

lake.deps_arg = deps_arg

-- expand_args() goes one step further than deps_arg(); it will expand a wildcard expression into a list of files
-- as well as handling lists as strings. If the argument is a table, it will attempt
-- to expand each string - e.g. {'a','b c'} => {'a','b','c'}
function expand_args(src,ext,recurse,base)
    if type(src) == 'table' then
        local res = {}
        for s in list_(src) do
            for l in list_(split_list(s)) do
                if base then l = join(base,l) end
                append_list(res,expand_args(l,ext,recurse))
            end
        end
        return res
    end
    local items = split_list(src)
    if #items > 1 then return expand_args(items,ext,recurse,base) end
    src = items[1]
    -- @doc 'src' if it is a directory, then regard that as an implicit wildcard
    if base then src = join(base,src) end
    if ext and isdir(src) and not isfile(src..ext) then
        src = src..'/*'
    end
    if src:find('%*') then
        if src:find '%*$' then src = src..ext end
        return files_from_mask(src,recurse)
    else
        local res = deps_arg(src) --,base)
        if ext then
            -- add the extension to the list of files, unless there's already an extension...
            for i = 1,#res do
                if extension_of(res[i]) == '' then res[i] = res[i]..ext end
            end
        end
        return res
    end
end
lake.expand_args = expand_args

function utils.quote(fun)
    return function(...) return fun(...) end
end

utils.foreach = utils.quote(forall)

local tmt,tcnt = {},1

function istarget (t)
    return type(t) == 'table' and getmetatable(t) == tmt
end

local function new_target(tname,deps,cmd,upfront)
    local t = setmetatable({},tmt)
    if tname == '*' then
        tname = '*'..tcnt
        tcnt = tcnt + 1
    end
    t.target = tname
    t.deps = deps_arg(deps)
    t.cmd = cmd
    if upfront then
        table.insert(all_targets_list,1,t)
    else
        append(all_targets_list,t)
    end
    if type(cmd) == 'string' then
        if specfile then
            -- @doc [checking against specfile]  for each target, we check the command generated
            -- against the stored command, and delete the target if the command is different.
            local oldcmd = specfile:read()
            if oldcmd ~= cmd then
                if verbose then
                    print(oldcmd); print(cmd)
                    print('command changed: removing '..tname)
                end
                os.remove(tname)
            end
        end
        if outspec then outspec:write(cmd,'\n') end
    end
    return t
end

function phony(deps,cmd)
    return new_target('*',deps,cmd,true)
end

--- @doc [Rule Objects] ----
-- serve two functions (1) define a conversion operation between file types (such as .c -> .o)
-- and (2) manage a list of dependent files.

local rt = {} -- metatable for rule objects
rt.__index = rt

-- create a rule object, mapping input files with extension @in_ext to
-- output files with extension @out_ext, using an action @cmd
function rule(in_ext,out_ext,cmd)
    local r = {}
    r.in_ext = in_ext
    r.out_ext = out_ext
    r.cmd = cmd
    r.targets = {}
    r.depends_on = rt.depends_on
    setmetatable(r,rt)
    return r
end

-- this is used by the CL output parser: e.g, cl will put out 'hello.c' and this
-- code will return 'release\hello.d' and '..\hello.c'
function rt.deps_filename (r,name)
    local t = find_list(r.targets,'base',splitext(name))
    return replace_extension(t.target,'.d'), t.input
end

-- add a new target to a rule object, with name @tname and optional dependencies @deps.
-- @tname may have an extension, but this will be ignored, unless the in-extension is '*',
-- in which case we use this extension for the output as well.
--
-- if there are no explicit dependencies, we assume that we are dependent on the input file.
-- Also, any global dependencies that have been set for this rule with depends_on().
-- In addition, we look for .d dependency files that have been auto-generated by the compiler.
function rt.add_target(r,tname,deps)
    local in_ext,out_ext, ext = r.in_ext,r.out_ext
    tname,ext = splitext(tname)
    if in_ext == '*' then -- assume that out_ext is also '*'
        in_ext = ext
        out_ext = ext
    end
    local input = tname..in_ext
    local base = basename(tname)
    local target_name = base..out_ext
    if r.output_dir then
        target_name = join(r.output_dir,target_name)
    elseif r.lang and r.lang.output_in_same_dir then
        target_name = replace_extension(input,r.out_ext)
    end
    if deps then
        deps = deps_arg(deps)
        table.insert(deps,1,input)
    end
    if not deps and r.lang and r.lang.uses_dfile then
        deps = deps_from_d_file(replace_extension(target_name,'.d'))
    end
    if not deps then
        deps = {input}
    end
    if r.global_deps then
        append_list(deps,r.global_deps)
    end
    local t = new_target(target_name,deps,r.cmd)
    t.name = tname
    t.input = input
    t.rule = r
    t.base = base
    t.cflags = r.cflags
    append(r.targets,t)
    return t
end

-- @doc the rule object's call operation is overloaded, equivalent to add_target() with
-- the same arguments @tname and @deps.
-- @tname may be a shell wildcard, however.
function rt.__call(r,tname,deps)
    if tname:find('%*') then
        if extension_of(tname) == '' then
            tname = tname..r.in_ext
        end
        for f in mask(tname) do
            r:add_target(f,deps)
        end
    else
        r:add_target(tname,deps)
    end
    return r
end

function rt:get_targets()
    local ldeps =  column_list(self.targets,'target')
    if #ldeps == 0 and self.parent then
        -- @doc no actual files were added to this rule object.
        -- But the rule has a parent, and we can deduce the single file to add to this rule
        -- (This is how a one-liner like c.program 'prog' works)
        local base = splitext(self.parent.target)
        local t = self:add_target(base)
        return {t.target}
    else
        return ldeps
    end
end

local function isrule(r)
    return r.targets ~= nil
end

function rt.depends_on(r,s)
    s = deps_arg(s)
    if not r.global_deps then
        r.global_deps = s
    else
        append_list(r.global_deps,s)
    end
end

local function parse_deps_line (line)
    line = line:gsub('\n$','')
    -- each line consists of a target, and a list of dependencies; the first item is the source file.
    local target,deps = line:match('([^:]+):%s*(.+)')
    if target and deps then
        return target,split_list(deps)
    end
end

function deps_from_d_file(fname)
    local line,err = file.read(fname)
    if not line or #line == 0 then return false,err end
    local _,deps = parse_deps_line(line:gsub(' \\',' '))
    -- @doc any absolute paths are regarded as system headers; don't include.
    local res = {}
    for d in list_(deps) do
        if not isabs(d) then
            append(res,d)
        end
    end
    return res
end

function rules_from_deps(file,extract_include_paths)
    extract_include_paths = not extract_include_paths -- default is true!
    local f,err = io.open(file,'r')
    if not f then quit(err) end
    local rules = {}
    for line in readlines(f) do  -- will respect '\'
        if not line:find('^#') then -- ignore Make-style comments
            local target,deps = parse_deps_line(line)
            if target and deps then
                -- make a rule to translate the source file into an object file,
                -- and set the include paths specially, unless told not to...
                local paths
                if extract_include_paths then
                    paths = {}
                    for i = 2,#deps do
                        local path = splitpath(deps[i])
                        if path ~= '' then
                            append_unique(paths,path)
                        end
                    end
                end
                append(rules,lake.compile{deps[1],incdir=paths,nodeps=true})
            end
        end
    end
    f:close()
    return depends(unpack(rules))
end

function get_target_list (t)
    if type(t) == 'table' and t.target_list then return t.target_list end
end

function make_target_list(ls)
    return {target_list = ls}
end

-- convenient function that takes a number of dependency arguments and turns them
-- into a target list.
function depends(...)
    local ls = {}
    local args = {...}
    if #args == 1 and is_simple_list(args[1]) then
        args = args[1]
    end
    for t in list_(args) do
        local tl = get_target_list(t)
        if tl then
            append_list(ls,tl)
        else
            append(ls,t)
        end
    end
    return make_target_list(ls)
end

-- @doc returns a copy of all the targets. The variable ALL_TARGETS is
-- predefined with a copy
function all_targets()
    return column_list(all_targets_list,'target')
end

-- given a filename @fname, find out the corresponding target object.
function target_from_file(fname,target)
    return find_list(all_targets_list,target or 'target',fname)
end

-- these won't be initially subsituted
local basic_variables = {INPUT=true,TARGET=true,DEPENDS=true,LIBS=true,CFLAGS=true}

function exec(s,dont_fail)
    local cmd = subst(s)
    print(cmd)
    if not TESTING then
        local res = os.execute(cmd)
        if res ~= 0 then
            if not dont_fail then quit ("failed with code %d",res) end
            return res
        end
    end
end

function subst_all_but_basic(s)
    return subst(s,basic_variables)
end

local current_rule,first_target,combined_targets = nil,nil,{}

function fire(t)
    if not t.fake then
        -- @doc compilers often support the compiling of multiple files at once, which
        -- can be a lot faster. The trick here is to combine the targets of such tools
        -- and make up a fake target which does the multiple compile.
        if t.rule and t.rule.can_combine then
            -- collect a list of all the targets belonging to this particular rule
            if not current_rule then
                current_rule = t.rule
                first_target = t
            end
            if current_rule == t.rule then
                append(combined_targets,t.input)
                -- this is key: although we defer compilation, we have to immediately
                -- flag the target as modified
                lfs.touch(t.target)
                return
            end
        end
        -- a target with new rule was encountered, and we have to actually compile the
        -- combined targets using a fake target.
        if #combined_targets > 0 then
            local fake_target = copy_table(first_target)
            fake_target.fake = true
            fake_target.input = concat(combined_targets,' ')
            fire(fake_target)
            current_rule,first_target,combined_targets = nil,nil,{}
            -- can now pass through and fire the target we were originally passed
        end
    end

    local ttype = type(t.cmd)
    --- @doc basic variables available to actions:
    -- they are kept in the basic_variables table above, since then we can use
    -- subst_all_but_basic() to replace every _other_ variable in command strings.
    INPUT = t.input
    TARGET = t.target
    if t.deps then
        local deps = t.deps
        if t.link and t.link.massage_link then
            deps = t.link.massage_link(t.name,deps,t)
        end
        DEPENDS = concat(deps,' ')
    end
    LIBS = t.libs
    CFLAGS = t.cflags
    if t.dir then change_dir(t.dir) end
    if ttype == 'string' and t.cmd ~= '' then -- it's a non-empty shell command
        if t.rule and t.rule.filter and not TESTING then
            local cmd = subst(t.cmd)
            print(cmd)
            local filter = t.rule.filter
            local tmpfile = file.temp()
            local redirect,outf
            if t.rule.stdout then
                redirect = '>'; outf = io.stdout
            else
                redirect = '2>'; outf = io.stderr
            end
            local code = os.execute(cmd..' '..redirect..' '..tmpfile)
            filter({TARGET,INPUT,t.rule},'start')
            local inf = io.open(tmpfile,'r')
            for line in inf:lines() do
                line = filter(line)
                if line then outf:write(line,'\n') end
            end
            inf:close()
            os.remove(tmpfile)
            filter(t.base,'end')
            if code ~= 0 then quit ("failed with code %d",code) end
        else
            exec(t.cmd)
        end
    elseif ttype == 'function' then -- a Lua function
        (t.cmd)(t)
    else -- nothing happened, but we are satisfied (empty command target)
        nbuild = nbuild - 1
    end
    if t.dir then change_dir '!' end
    nbuild = nbuild + 1
end

function check(time,t)
    if not t then return end
    if not t.deps then
        -- unconditional action
        fire(t)
        return
    end

    if verbose then print('target: '..t.target) end

    if t.deps then
        -- the basic out-of-date check compares last-written file times.
        local deps_changed = false
        for dfile in list_(t.deps) do
            local tm = filetime(dfile)
            check (tm,target_from_file(dfile))
            tm = filetime(dfile)
            if verbose then print(t.target,dfile,time,tm) end
            deps_changed = deps_changed or tm > time or tm == -1
        end
        -- something's changed, so do something!
        if deps_changed then
            fire(t)
        end
    end
end

local function get_deps (deps)
    if isrule(deps) then -- this is a rule object which has a list of targets
        return deps:get_targets()
    elseif istarget(deps) then
        return deps.target
    else
        return deps
    end
end

-- flattens out the list of dependencies
local function deps_list (targets)
    deps = {}
    for target in list_(targets) do
        target = get_deps(target)
        if type(target) == 'string' then
            append(deps,target)
        else
            append_list(deps,target)
        end
    end
    return deps
end

function get_dependencies (deps)
    deps = get_deps(deps)
    local tl = get_target_list(deps)
    if tl then -- this is a list of dependencies
        deps = deps_list(tl)
    elseif is_simple_list(deps) then
        deps = deps_list(deps)
    end
    return deps
end

-- often the actual dependencies are not known until we come to evaluate them.
-- this function goes over all the explicit targets and checks their dependencies.
-- Dependencies may be simple file names, or rule objects, which are here expanded
-- into a set of file names.  Also, name references to files are resolved here.
function expand_dependencies(t)
    if not t or not t.deps then return end
    local deps = get_dependencies(t.deps)
    -- we already have a list of explicit dependencies.
    -- @doc Lake allows dependency matching against target _names_ as opposed
    -- to target _files_, for instance 'lua51' vs 'lua51.dll' or 'lua51.so'.
    -- If we can't match a target by filename, we try to match by name
    -- and update the dependency accordingly.
    for i = 1,#deps do
        local name = deps[i]
        if type(name) ~= 'string' then
            name = get_dependencies(name)
            deps[i] = name
            if type(name) ~= 'string' then
                dump(name,'NOT FILE')
                quit("not a file name")
            end
        end
        local target = target_from_file(name)
        if not target then
            target = target_from_file(name,'name')
            if target then
                deps[i] = target.target
            elseif not exists(name) then
                quit("cannot find dependency '%s'",name)
            end
        end
    end
    if verbose then dump(deps,t.target) end

    -- by this point, t.deps has become a simple array of files
    t.deps = deps

    for dfile in list_(t.deps) do
        expand_dependencies (target_from_file(dfile))
    end
end

local synth_target,synth_args_index

local function update_pwd ()
    local dir = lfs.currentdir()
    if WINDOWS then dir = dir:lower() end -- canonical form
    PWD = dir..DIRSEP
end

local dir_stack = {}
local push,pop = table.insert,table.remove

function change_dir (path)
    if path == '!' or path == '<' then
        lfs.chdir(pop(dir_stack))
        print('restoring directory')
    else
        push(dir_stack,lfs.currentdir())
        local res,err = lfs.chdir(path)
        if not res then quit(err) end
        print('changing directory',path)
    end
    update_pwd()
end


local function safe_dofile (name)
    local stat,err = pcall(dofile,name)
    if not stat then
        quit(err)
    end
end

local lakefile
local unsatisfied_needs = {}

local function process_args()
    -- arg is not set in interactive lua!
    if arg == nil then return end
    local write_needs
    local function exists_lua(name) return exists(name) or exists(name..'.lua') end
    LUA_EXE = quote_if_necessary(arg[-1])
    STRICT = true
    -- @doc [config] also try load ~/.lake/config
    local home = expanduser '~/.lake'
    local lconfig = exists_lua(join(home,'config'))
    if lconfig then
        safe_dofile(lconfig)
    end
    -- @doc [config] try load lakeconfig in the current directory
    local lakeconfig = exists_lua 'lakeconfig'
    if lakeconfig then
        safe_dofile (lakeconfig)
    end
    if not PLAT then
        if not WINDOWS then PLAT = shell('uname -s')
        else PLAT='Windows'
        end
    end
    update_pwd()

    -- @doc [config] the environment variable LAKE_PARMS can be used to supply default global values,
    -- in the same <var>=<value> form as on the command-line; pairs are separated by semicolons.
    local parms = env 'LAKE_PARMS'
    if parms then
        for pair in list_(split(parms,';')) do
            process_var_pair(pair)
        end
    end
    local no_synth_target
    local use_lakefile = true
    local i = 1
    while i <= #arg do
        local a = arg[i]
        local function getarg() local res = arg[i+1]; i = i + 1; return res end
        if process_var_pair(a) then
            -- @doc <name>=<val> pairs on command line for setting globals
        elseif a:sub(1,1) == '-' then
            local opt = a:sub(2)
            if opt == 'v' then
                verbose = true
            elseif opt == 'h' or opt == '-help' then
                print(usage)
                os.exit(0)
            elseif opt == 't' then
                TESTING = true
            elseif opt == 'w' then
                write_needs = true
            elseif opt == 'n' then
                no_synth_target = true
            elseif opt == 'f' then
                lakefile = getarg()
            elseif opt == 'e' then
                lakefile = file.temp_copy(getarg())
            elseif opt == 's' then
                STRICT = true
            elseif opt == 'g' then
                DEBUG = true
            elseif opt == 'd' then
                change_dir(getarg())
            elseif opt == 'p' then
                lakefile = file.temp_copy(("tp,name = lake.deduce_tool('%s'); tp.program(name)"):format(arg[i+1]))
                i = i + 1
            elseif opt == 'lua' or opt == 'l' then
                local name,lua = getarg(),'false'
                if opt=='lua' then lua = 'true' end
                lakefile,err = file.temp_copy(("tp,name = lake.deduce_tool('%s'); tp.shared{name,lua=%s}"):format(name,lua))
            end
        else
            if not no_synth_target and a:find('%.') and exists(a) then
                -- @doc 'synth-target' unless specifically switched off with '-t',
                -- see if we have a suitable rule for processing
                -- an existing file with this extension.
                local _,_,rule = lake.deduce_tool(a,true)
                if _ then
                    lake.set_flags()
                    use_lakefile = false
                    -- if there's no specific rule for this tool, we assume that there's
                    -- a program target for this file; we keep the target for later,
                    -- when we will try to execute its result.
                    if not rule then
                        synth_target = lake.program (a)
                        synth_args_index = i + 1
                    else
                        rule.in_ext = extension_of(a)
                        rule(a)
                    end
                    break
                end
                -- otherwise, it has to be a target
            end
            append(specific_targets,a)
        end
        i = i + 1
     end
    if CONFIG_FILE then
        safe_dofile (CONFIG_FILE)
    end
     lake.set_flags()
    -- if we are called as a program, not as a library, then invoke the specified lakefile
    if arg[0] == 'lake.lua' or arg[0]:find '[/\\]lake%.lua$' then
        if use_lakefile then
            local orig_lakefile = lakefile
            lakefile = exists_lua(lakefile or 'lakefile')
            if not lakefile then
                quit("'%s' does not exist",orig_lakefile or 'lakefile')
            end
            specfile = lakefile..'.spec'
            specfile = io.open(specfile,'r')
            outspec = io.open(TMPSPEC,'w')
            safe_dofile(lakefile)
        end
        if next(unsatisfied_needs) then
            local out = write_needs and io.open('lakeconfig.lua','w') or io.stdout
            for package,vars in pairs(unsatisfied_needs) do
                out:write(('--- variables for package %s\n'):format(package))
                for _,v in ipairs(vars) do out:write(v,'\n') end
                out:write('----\n')
            end
            local msg = "unsatisfied needs"
            if write_needs then
                out:close()
                msg = msg..": see lakeconfig.lua"
            end
            quit (msg)
        end
        go()
        finalize()
    end
end

function finalize()
    if specfile then pcall(specfile.close,specfile) end
    if outspec then
        local stat,err = pcall(outspec.close,outspec)
        if stat then
            file.copy(TMPSPEC,lakefile..'.spec')
        else
            print('unable to recreate spec file: ',err)
        end
    end
end


-- recursively invoke lake at the given @path with the arguments @args
function lake_(path,args)
    args = args or ''
    exec('lake -d '..path..'  '..args,true)
end

utils.make_callable(lake,lake_)

local on_exit_list = {}

-- @doc can arrange for a function to be called after the lakefile returns
-- to lake, but before the dependencies are calculated. This can be used
-- to generate a default target for special applications.
function lake.on_exit(fun)
    append(on_exit_list,fun)
end

function go()

    for _,exit in ipairs(on_exit_list) do
        exit()
    end

    if #all_targets_list == 0 then
        specfile = nil
        outspec = nil
        quit('no targets defined')
    end

    for tt in list_(all_targets_list) do
        expand_dependencies(tt)
    end
    ALL_TARGETS = all_targets()
    if verbose then dump(ALL_TARGETS,'targets') end

    local synthesize_clean
    local targets = {}
    if #specific_targets > 0 then
        for tname in list_(specific_targets) do
            t = target_from_file(tname)
            if not t then
                -- @doc 'all' is a synonym for the first target
                if tname == 'all' then
                    table.insert(targets,all_targets_list[1])
                    table.remove(all_targets_list,1)
                elseif tname ~= 'clean' then
                    quit ("no such target '%s'",tname)
                else --@doc there is no clean target, so we'll construct one later
                    synthesize_clean = true
                    append(targets,'clean')
                end
            end
            append(targets,t)
        end
    else
        -- @doc by default, we choose the first target, just like Make.
        -- (Program/library targets force themselves to the top)
        append(targets,all_targets_list[1])
    end
    -- if requested, generate a default clean target, using all the targets.
    if synthesize_clean then
        local t = new_target('clean',nil,function()
            remove(ALL_TARGETS)
        end)
        targets[index_list(targets,'clean')] = t
    end
    for t in list_(targets) do
        t.time = filetime(t.target)
        check(t.time,t)
    end
    if nbuild == 0 then
        if not synth_target then print 'lake: up to date' end
    end
    -- @doc 'synth-target' a program target was implicitly created from the file on the command line;
    -- execute the target, passing the rest of the parms passed to Lake, unless we were
    -- explicitly asked to clean up.
    if synth_target and not synthesize_clean then
        lake.run(synth_target,arg,synth_args_index)
    end
end

-- @doc lake.run will run a program or a target, given some arguments. It will
-- only include arguments starting at istart, if defined. If it is a target,
-- the target's language may define a runner; otherwise we look for an interpreter
-- or default to local execution of the program.
function lake.run(prog,args,istart)
    local args = parm_list_concat(args,istart)
    if istarget(prog) then
        prog = prog.target
        local lang = prog.rule and prog.rule.lang
        if lang and lang.runner then
            return lang.runner(prog,args)
        end
    end
    local ext = extension_of(prog)
    local runner = interpreters[ext]
    if runner then runner = runner..' '
    else runner = LOCAL_EXEC
    end
    return exec(runner..prog..args)
end

function lake.deduce_tool(fname,no_error)
    local name,ext,tp
    if type(fname) == 'table' then
        name,ext = fname, fname.ext
        if not ext then quit("need to specify 'ext' field for program()") end
    else
        name,ext = splitext(fname)
        if ext == '' then
            if no_error then return end
            quit('need to specify extension for input to program()')
        end
    end
    tp = extensions[ext]
    if not tp then
        if no_error then return end
        quit("unknown file extension '%s'",ext)
    end
    tp.ext = ext
    return tp,name,tp.rule
end

local flags_set

local function opt_flag (flag,opt)
    if opt then
        if opt == true then opt = OPTIMIZE
        elseif opt == false then return ''
        end
        return flag..opt
    else
        return ''
    end
end

-- -@doc [GLOBALS]
local known_globals = {
    --These can be set on the command-line (like make) and in the environment variable LAKE_PARMS
    CC=true, -- the C compiler (gcc unless cl is available)
    CXX=true, -- the C++ compiler (g++ unless cl is available)
    FC=true, -- the Fortran compiler (gfortran)
    OPTIMIZE=true, -- (O1)
    STRICT=true, -- strict compile (also -s command-line flag)
    DEBUG=true, -- debug build (also -g command-line flag)
    PREFIX=true, -- (empty string. e.g. PREFIX=arm-linux makes CC become arm-linux-gcc etc)
    LUA_INCLUDE_DIR=true,
    LUA_LIB_DIR=true, -- (usually deduced from environment)
    WINDOWS=true, -- true for Windows
    PLAT=true, -- platform deduced from uname if not windows, 'Windows' otherwise
    MSVC=true, -- true if we're using cl
    EXE_EXT=true, --  extension of programs on this platform
    DLL_EXT=true, -- extension of shared libraries on this platform
    DIRSEP=true, -- directory separator on this platform
    NO_COMBINE=true, -- don't allow the compiler to compile multiple files at once (if it is capable)
    NODEPS=true, -- don't do automatic dependency generation
}

function lake.set_flags(parms)
    if not parms then
        if not flags_set then flags_set = true else return end
    else
        for k,v in pairs(parms) do
            _G[k] = v
        end
    end
    -- @doc Microsft Visual C++ compiler prefered on Windows, if present
    if PLAT=='Windows' and utils.which 'cl' and not CC then
        CC = 'cl'
        CXX = 'cl'
        PREFIX = ''
    else
        -- @doc if PREFIX is set, then we use PREFIX-gcc etc. For example,
        -- if PREFIX='arm-linux' then CC becomes 'arm-linux-gcc'
        if PREFIX and #PREFIX > 0 then
            PREFIX = PREFIX..'-'
            CC = PREFIX..'gcc'
            CXX = PREFIX..'g++'
            FC = PREFIX..'gfortran'
        else
            PREFIX = ''
            CC = CC or 'gcc'
        end
    end
    if not CXX and CC == 'gcc' then
        CXX = 'g++'
        FC = 'gfortran'
    end
    -- @doc The default value of OPTIMIZE is O1
    if not OPTIMIZE then
        OPTIMIZE = 'O1'
    end
    if CC ~= 'cl' then -- must be 'gcc' or something compatible
        c.init_flags = function(debug,opt,strict)
            local flags = choose(debug,'-g',opt_flag('-',opt))
            if strict then
                -- @doc 'strict compile' (-s) uses -Wall for gcc; /WX for cl.
                flags = flags .. ' -Wall'
            end
            return flags
        end
        c.auto_deps = '-MMD'
        AR = PREFIX..'ar'
        c.compile = '$(CC) -c $(CFLAGS)  $(INPUT) -o $(TARGET)'
        c.compile_combine = '$(CC) -c $(CFLAGS)  $(INPUT)'
        c99.compile = '$(CC) -std=c99 -c $(CFLAGS)  $(INPUT) -o $(TARGET)'
        c99.compile_combine = '$(CC) -std=c99 -c $(CFLAGS)  $(INPUT)'
        c.link = '$(CC) $(DEPENDS) $(LIBS) -o $(TARGET)'
        c99.link = c.link
        f.compile = '$(FC) -c $(CFLAGS)  $(INPUT)'
        flink = '$(FC) $(DEPENDS) $(LIBS) -o $(TARGET)'
        cpp.compile = '$(CXX) -c $(CFLAGS)  $(INPUT) -o $(TARGET)'
        cpp.compile_combine = '$(CXX) -c $(CFLAGS)  $(INPUT)'
        cpp.link = '$(CXX) $(DEPENDS) $(LIBS) -o $(TARGET)'
        c.lib = '$(AR) rcu $(TARGET) $(DEPENDS) && ranlib $(TARGET)'
        C_LIBPARM = '-l'
        C_LIBPOST = ' '
        C_LIBDIR = '-L'
        c.incdir = '-I'
        C_DEFDEF = '-D'
        if PLAT=='Darwin' then
            C_LINK_PREFIX = 'MACOSX_DEPLOYMENT_TARGET=10.3 '
            C_LINK_DLL = ' -bundle -undefined dynamic_lookup'
        else
            C_LINK_DLL = '-shared'
        end
        c.obj_ext = '.o'
        LIB_PREFIX='lib'
        LIB_EXT='.a'
        SUBSYSTEM = '-Xlinker --subsystem -Xlinker  '  -- for mingw with Windows GUI
        if PLAT ~= 'Darwin' then
            C_EXE_EXPORT = ' -Wl,-E'
        else
            C_EXE_EXPORT = ''
        end
        C_STRIP = ' -Wl,-s'
        C_LIBSTATIC = ' -static'
        c.uses_dfile = 'slash'
        -- @doc under Windows, we use the .def file if provided when linking a DLL
        function c.massage_link (name,deps)
            local def = exists(name..'.def')
            if def and WINDOWS then
                deps = copy_list(deps)
                append(deps,def)
            end
            return deps
        end

        wresource.compile = 'windres $(CFLAGS) $(INPUT) $(TARGET)'
        wresource.obj_ext='.o'

    else -- Microsoft command-line compiler
        MSVC = true
        c.init_flags = function(debug,opt,strict)
            local flags = choose(debug,'/Zi',opt_flag('/',opt))
            if strict then -- 'warnings as errors' might be a wee bit overkill?
                flags = flags .. ' /WX'
            end
            return flags
        end
        c.compile = 'cl /nologo -c $(CFLAGS)  $(INPUT) /Fo$(TARGET)'
        c.compile_combine = 'cl /nologo -c $(CFLAGS)  $(INPUT)'
        c.link = 'link /nologo $(DEPENDS) $(LIBS) /OUT:$(TARGET)'
        -- enabling exception unwinding is a good default...
        -- note: VC 6 still has this as '/GX'
        cpp.compile = 'cl /nologo /EHsc -c $(CFLAGS)  $(INPUT) /Fo$(TARGET)'
        cpp.compile_combine = 'cl /nologo /EHsc -c $(CFLAGS) $(INPUT)'
        cpp.link = c.link
        c.lib = 'lib /nologo $(DEPENDS) /OUT:$(TARGET)'
        c.auto_deps = '/showIncludes'
        function c.post_build(ptype,args)
            if args and (args.static==false or args.dynamic) then
                local mtype = choose(ptype=='exe',1,2)
                return 'mt -nologo -manifest $(TARGET).manifest -outputresource:$(TARGET);'..mtype
            end
        end
        function c.massage_link (name,deps,t)
            local odeps = deps
            -- a hack needed because we have to link against the import library, not the DLL
            deps = {}
            for l in list_(odeps) do
                if extension_of(l) == '.dll' then l = replace_extension(l,'.lib') end
                append(deps,l)
            end
            -- if there was an explicit .def file, use it
            local def = exists(name..'.def')
            if def then
                append(deps,'/DEF:'..def)
            elseif t.lua and t.ptype == 'dll' then
                -- somewhat ugly hack: if no .def and this is a Lua extension, then make sure
                -- the Lua extension entry point is visible.
                append(deps,' /EXPORT:luaopen_'..name)
            end
            return deps
        end
        -- @doc A language can define a filter which operates on the output of the
        -- compile tool. It is used so that Lake can parse the output of /showIncludes
        -- when using MSVC and create .d files in the same format as generated by GCC
        -- with the -MMD option.
        local rule,file_pat,dfile,target,ls
        local function write_deps()
            local outd = io.open(dfile,'w')
            outd:write(target,': ',concat(ls,' '),'\n')
            outd:close()
        end
        if not NODEPS then
        function c.filter(line,action)
          -- these are the three ways that the filter is called; initially with
          -- the input and the target, finally with the name, and otherwise
          -- with each line of output from the tool. This stage can filter the
          -- the output by returning some modified string.
          if action == 'start' then
            target,rule = line[1],line[3]
            file_pat = '.-%'..rule.in_ext..'$'
            dfile = nil
          elseif action == 'end' then
            write_deps()
          elseif line:match(file_pat) then
            local input
            -- the line containing the input file
            if dfile then write_deps() end
            dfile,input = rule:deps_filename(line)
            ls = {input}
          else
              local file = line:match('Note: including file:%s+(.+)')
              if file then
                if not isabs(file) then -- only relative paths are considered dependencies
                    append(ls,file)
                end
              else
                return line
              end
            end
        end
        end
        c.stdout = true
        C_LIBPARM = ''
        C_LIBPOST = '.lib '
        C_LIBDIR = '/LIBPATH:'
        c.incdir = '/I'
        C_DEFDEF = '/D'
        C_LINK_DLL = '/DLL'
        c.obj_ext = '.obj'
        LIB_PREFIX=''
        C_STRIP = ''
        LIB_EXT='_static.lib'
        SUBSYSTEM = '/SUBSYSTEM:'
        C_LIBDYNAMIC = 'msvcrt.lib' -- /NODEFAULTLIB:libcmt.lib'
        c.uses_dfile = 'noslash'

        wresource.compile = 'rc $(CFLAGS) /fo$(TARGET) $(INPUT) '
        wresource.obj_ext='.res'
        wresource.incdir ='/i'

    end
end

function lake.output_filter (lang,filter)
    local old_filter = lang.filter
    lang.filter = function(line,action)
        if not action then
            if old_filter then line = old_filter(line) end
            return filter(line)
        else
            if old_filter then old_filter(line,action) end
        end
    end
end

function concat_arg(pre,arg,sep,base)
    return ' '..concat_list(pre,deps_arg(arg,base),sep)
end

local function check_c99 (lang)
    if lang == c99 and CC == 'cl' then
        quit("C99 is not supported by MSVC compiler")
    end
end

local function _compile(name,compile_deps,lang)
    local args = (type(name)=='table') and name or {}
    local cflags = ''
    if lang.init_flags then
        cflags = lang.init_flags(pick(args.debug,DEBUG), pick(args.optimize,OPTIMIZE), pick(args.strict,STRICT))
    end
    check_c99(lang)

    compile_deps = args.compile_deps or args.headers
    -- @doc 'defines' any preprocessor defines required
    if args.defines then
        cflags = cflags..concat_arg(C_DEFDEF,args.defines,' ')
    end
    -- @doc 'incdir' specifying the path for finding include files

    if args.incdir then
        cflags = cflags..concat_arg(lang.incdir,args.incdir,' ',args.base)
    end

    -- @doc 'flags' extra flags for compilation
    if args.flags then
        cflags = cflags..' '..args.flags
    end
    -- @doc 'nodeps' don't automatically generate dependencies
    if not args.nodeps and not NODEPS and lang.auto_deps then
        cflags = cflags .. ' ' .. lang.auto_deps
    end
    local can_combine = not args.odir and not NO_COMBINE and lang.compile_combine
    local compile_cmd = lang.compile
    if can_combine then compile_cmd = lang.compile_combine end
    local compile_str = subst_all_but_basic(compile_cmd)
    local ext = args and args.ext or lang.ext

    local cr = rule(ext,lang.obj_ext or ext,compile_str)

    -- @doc 'compile_deps' can provide a list of files which all members of the rule
    -- are dependent on.
    if compile_deps then cr:depends_on(compile_deps) end
    cr.cflags = cflags
    cr.can_combine = can_combine
    cr.lang = lang
    return cr
end

function find_include (f)
    if not WINDOWS then
        return exists('/usr/include/'..f) or exists('/usr/share/include/'..f)
    else
       -- ??? no way to tell ???
    end
end

------------ Handling needs ------------

local extra_needs = {}

function define_need (name,callback)
    extra_needs[name] = callback
end

local function examine_config_vars(package)
    -- @doc [needs] If we're trying to match a need 'frodo', then we
    -- generate FRODO_INCLUDE_DIR, FRODO_LIB_DIR, FRODO_LIBS, FRODO_DIR
    -- and look them up globally.  Not all of these are needed. For instance, if only
    -- FRODO_DIR is specified then Lake will try FRODO_DIR/include and FRODO_DIR/lib,
    -- and assume that the libname is simply frodo (unless FRODO_LIBS is also specfiied)
    -- On Unix, a C/C++ need generally needs include and lib dirs, plus library name if
    -- it isn't identical to the need name. However a lib dir is only essential for Windows,
    -- which has no convenient system-wide lib directory.
    --
    -- If this check fails, then Lake can generate skeleton configuration files for
    -- the needs.
    local upack = package:upper():gsub('%W','_')
    local incdir_v = upack..'_INCLUDE_DIR'
    local libdir_v = upack..'_LIB_DIR'
    local libs_v = upack..'_LIBS'
    local dir_v = upack..'_DIR'
    local incdir,libdir,libs,dir = _G[incdir_v],_G[libdir_v],_G[libs_v],_G[dir_v]

    local function checkdir(val,var,default)
        local none = val == nil
        local nodir
        if not default then nodir = not none and not path.isdir(val) end
        default = default or 'NIL'
        if none or nodir then
            if not unsatisfied_needs[package] then
                unsatisfied_needs[package] = {}
            end
            append(unsatisfied_needs[package],("%s = '%s' --> %s!"):format(var,val or default,none and 'please set' or 'not a dir'))
            return false
        end
        return true
    end

    if dir ~= nil then -- this is a common pattern on Windows; FOO\include, FOO\lib
        if checkdir(dir,dir_v) then
            if not incdir then incdir = join(dir,'include') end
            if not libdir then libdir = join(dir,'lib') end
            if not libs then libs = package end
        end
    end
    checkdir(incdir,incdir_v)
    -- generally you will always need a libdir for Windows; otherwise only check if specified
    if WINDOWS or libdir ~= nil then checkdir(libdir,libdir_v) end
    checkdir(libs,libs_v,package)
    return {incdir = incdir, libdir = libdir, libs = libs}
end

local pkg_config_present

-- @doc [needs] handling external needs - if an alias @name for @package is provided,
-- then this package is available using the alias (e.g. 'gtk') and _must_ be handled by
-- pkg-config.
function lake.define_pkg_need (name,package)
    local alias = package ~= nil
    define_need(name,function()
        local knows_package
         local null = " 2>&1 >"..choose(WINDOWS,'NUL','/dev/null')
        if not alias then package = name end
        if pkg_config_present == nil then
            pkg_config_present = utils.which 'pkg-config'
        end
        if alias and not pkg_config_present then
            quit("package "..package.." requires pkg-config on the path")
        end
        if pkg_config_present then
             if os.execute('pkg-config '..package..null) == 0 then
                knows_package = true
            elseif alias then
                quit("package "..package.." not known by pkg-config; please install")
            end
            if knows_package then
                local gflags = shell ('pkg-config --cflags '..package)
                local glibs = shell ('pkg-config --libs '..package)
                return {libflags=glibs,flags=gflags}
            end
        end
    end)
end

-- @doc [needs] unknown needs searched in this order:
-- lake.needs.name, config vars (NAME_INCLUDE_DIR etc) and then      pkg-config

local function handle_unknown_need (name)
    define_need(name,function()
        local ok,needs,nfun
        local pack,sub = split2(name,'%-')
        ok,nfun = pcall(require,'lake.needs.'..(sub or name))
        if ok then
            return nfun(sub)
        end
        needs = examine_config_vars(name)
        if not needs then
            lake.define_pkg_need(name)
            needs = extra_needs[name]()
            if needs then
                unsatisfied_needs[name] = nil
            end
        end
        return needs
    end)
end

local function append_to_field (t,name,arg)
    if arg and #arg > 0 then
        if not t[name] then
            t[name] = {}
        elseif type(t[name]) == 'string' then
            t[name] = deps_arg(t[name])
        end
        append_list(t[name],deps_arg(arg))
    end
end

-- @doc [needs] these are currently the built-in needs supported by Lake
local builtin_needs = {math=true,readline=true,dl=true,sockets=true,lua=true}

local update_lua_flags  -- forward reference

local function update_needs(ptype,args)
    local needs = args.needs
    -- @doc [needs] extra needs for all compile targets can be set with the NEEDS global.
    if NEEDS then
        if needs then needs = needs .. ' ' .. NEEDS
        else needs = NEEDS
        end
    end
    needs = deps_arg(needs)
    local libs,incdir = {},{}
    for need in list_(needs) do
        if not extra_needs[need] and not builtin_needs[need] then
            handle_unknown_need(need)
        end
        if extra_needs[need] then
            local res = extra_needs[need]()
            if res then
                append_to_field(args,'libs',res.libs)
                append_to_field(args,'incdir',res.incdir) -- ?? might be multiple!
                append_to_field(args,'defines',res.defines)
                append_to_field(args,'libdir',res.libdir)
                if res.libflags then args.libflags = concat_str(args.libflags,res.libflags,true) end
                if res.flags then args.flags = concat_str(args.flags,res.flags,true) end
            end
        else
            if need == 'lua' then
                update_lua_flags(ptype,args)
                args.lua = true
            elseif not WINDOWS then
                if need == 'math' then append(libs,'m')
                elseif need == 'readline' then
                    append(libs,'readline')
                    if PLAT=='Linux' then
                        append_list(libs,{'ncurses','history'})
                    end
                elseif need == 'dl' and PLAT=='Linux' then
                    append(libs,'dl')
                end
            else
                if need == 'sockets' then append(libs,'wsock32') end
            end
        end
    end
    append_to_field(args,'libs',libs)
    append_to_field(args,'incdir',incdir)
end

lake.define_pkg_need('gtk','gtk+-2.0')
lake.define_pkg_need('gthread','gthread-2.0')

define_need('windows',function()
    return { libs = 'user32 kernel32 gdi32 ole32 advapi32 shell32 imm32  uuid comctl32 comdlg32'}
end)

define_need('unicode',function()
    return { defines = 'UNICODE _UNICODE' }
end)


local lr_cfg

-- the assumption here that the second item on your Lua paths is the 'canonical' location. Adjust accordingly!
function get_lua_path (p)
    return package.path:match(';(/.-)%?'):gsub('/lua/$','')
end

local using_LfW

local function find_lua_dll (path)
    return exists(path,'lua5.1.dll') or exists(path,'lua51.dll') or exists(path,'liblua51.dll')
end

function update_lua_flags (ptype,args)
    if not LUA_LIBS then
        LUA_LIBS = 'lua5.1'
    end
    -- this var is set by Lua for Windows
    using_LfW = env 'LUA_DEV'
    if LUA_INCLUDE_DIR == nil then
        -- if LuaRocks is available, we ask it where the Lua headers are found...
        if not IGNORE_LUAROCKS and not lr_cfg and pcall(require,'luarocks.cfg') then
            lr_cfg = luarocks.cfg
            LUA_INCLUDE_DIR = lr_cfg.variables.LUA_INCDIR
            LUA_LIB_DIR = lr_cfg.variables.LUA_LIBDIR
            if WINDOWS then
                LUA_DLL = find_lua_dll(lr_cfg.variables.LUAROCKS_PREFIX..'/2.0')
            end
        elseif WINDOWS then -- no standard place, have to deduce this ourselves!
            local lua_path = utils.which(LUA_EXE)  -- usually lua, could be lua51, etc!
            if not lua_path then quit ("cannot find Lua on your path") end
            local path = dirname(lua_path)
            LUA_DLL = find_lua_dll(path)
            LUA_INCLUDE_DIR = exists(path,'include') or exists(path,'..\\include')
            if not LUA_INCLUDE_DIR then quit ("cannot find Lua include directory") end
            LUA_LIB_DIR = exists(path,'lib') or exists(path,'..\\lib')
            if not LUA_INCLUDE_DIR or not LUA_LIB_DIR then
                quit("cannot find Lua include and/or library files\nSpecify LUA_INCLUDE and LUA_LIBDIR")
            end
        else
            -- 'canonical' Lua install puts headers in sensible place
            if not find_include 'lua.h' then
                -- except for Debian, which also supports 5.0
                LUA_INCLUDE_DIR = find_include (LUA_LIBS..'/lua.h')
                if not LUA_INCLUDE then
                    quit ("cannot find Lua include files\nSpecify LUA_INCLUDE")
                end
                -- generally no need to link explicitly against Lua shared library
            else
                LUA_INCLUDE_DIR = ''
                LUA_LIB_DIR = nil
            end
        end
    end
    args.incdir = concat_str(args.incdir,LUA_INCLUDE_DIR)
    local use_import_lib = LUA_LIB_DIR
    if WINDOWS then
        -- recommended practice for MinGW is to link directly against the DLL
        if CC=='gcc' and not using_LfW then
            args.libflags = LUA_DLL
            use_import_lib = false
        else
            args.libs = concat_str(args.libs,LUA_LIBS)
        end
    end
    if using_LfW then -- specifically, Lua for Windows
        if CC=='gcc' then -- force link against VS2005 runtime
            args.libs = concat_str(args.libs,'msvcr80')
        else -- CL link may assume the runtime is installed
            args.dynamic = true
        end
    end
    if use_import_lib then
        args.libdir = concat_str(args.libdir,LUA_LIB_DIR)
    end
end

----- end of handling needs -----------


local program_fields = {
    name=true, -- name of target (or first value of table)
    lua=true,  -- build against Lua libs
    needs=true, -- higher-level specification of target link requirements
    libdir=true, -- list of lib directories
    libs=true, -- list of libraries
    libflags=true, -- list of flags for linking
    subsystem=true, -- (Windows) GUi application
    strip=true,  -- strip symbols from output
    rules=true,inputs=true, -- explicit set of compile targets
    shared=true,dll=true, -- a DLL or .so (with lang.library)
    deps=true, -- explicit dependencies of a target (or subsequent values in table)
    export=true, -- this executable exports its symbols
    dynamic=true, -- link dynamically against runtime (default true for GCC, override for MSVC)
    static=true, -- statically link this target
    headers=true, -- explicit list of header files (not usually needed with auto deps)
    odir=true, -- output directory; if true then use 'debug' or 'release'; prepends PREFIX
    src=true, -- src files, may contain directories or wildcards (extension deduced from lang or `ext`)
    exclude=true,	-- a similar list that should be excluded from the source list (e.g. if src='*')
    recurse=true, -- recursively find source files specified in src=wildcard
    ext=true, -- extension of source, if not the usual. E.g. ext='.cxx'
    defines=true, -- C preprocessor defines
    incdir=true, -- list of include directories
    flags=true,	 -- extra compile flags
    debug=true, -- override global default set by -g or DEBUG variable
    optimize=true, -- override global default set by OPTIMIZE variable
    strict=true, -- strict compilation of files
    base=true, -- base directory for source and includes
}

function lake.add_program_option(options)
    options = deps_arg(options)
    table.update(program_fields,table.set(options))
end

function check_options (args,fields,where)
    if not fields then
        fields = program_fields
        where = 'program'
    end
    for k,v in pairs(args) do
        if type(k) == 'string' and not fields[k] then
            quit("unknown %s option '%s'",where,k)
        end
    end
end

local function tail (t,istart)
    istart = istart or 2
    if #t < istart then return nil end
    return {select(istart,unpack(t))}
end

local function _program(ptype,name,deps,lang)
    local dependencies,src,except,cr,subsystem,args
    local libs = LIBS
    check_c99(lang)
    if type(name) == 'string' then name = { name } end
    if type(name) == 'table' then
        args = name
        check_options(args,program_fields,'program')
        append_table(args,lang.defaults)
        --- the name can be the first element of the args table
        name = args.name or args[1]
        deps = args.deps or tail(args)
        --- if the name contains wildcards, then we make up a new unique target
        --- that depends on all the files
        if is_mask(name) then
            local names = expand_args(name,args.ext or lang.ext,args.recurse,args.base)
            targets = {}
            for i,name in ipairs(names) do
                args.name = splitext(name)
                targets[i] = _program(ptype,args,'',lang)
            end
            return phony(targets,'')
        end
        src = args.src
        except = args.exclude
        subsystem = args.subsystem
        -- @doc lua=true is deprecated; prefer needs='lua' !
        if args.lua then
            update_lua_flags(ptype,args)
        end
        -- @doc 'needs' specifying libraries etc by 'needs', not explicitly
        if args.needs or NEEDS then
            update_needs(ptype,args)
        end

        -- @doc 'libdir' specifying the path for finding libraries
        if args.libdir then
            libs = libs..concat_arg(C_LIBDIR,args.libdir,' ')
        end
        -- @doc 'static' this program is statically linked against the runtime
        -- By default, GCC doesn't do this, but CL does
        if args.static then
            if not MSVC then libs = libs..C_LIBSTATIC	end
        elseif args.static==false then
            if MSVC then libs = libs..C_LIBDYNAMIC	end
        end
        if args.dynamic then
            if MSVC then libs = libs..C_LIBDYNAMIC	end
        end
        -- @doc 'libs' specifying the list of libraries to be linked against
        if args.libs then
            local libstr
            if lang.lib_handler then
                libstr = lang.lib_handler(args.libs)
            else
                libstr = concat_arg(C_LIBPARM,args.libs,C_LIBPOST)
            end
            libs = libs..libstr
        end
        -- @doc 'libflags' explicitly providing command-line for link stage
        if args.libflags then
            libs = libs..args.libflags
            if not args.defines then args.defines = '' end
            args.defines = args.defines .. '_DLL'
        end
        if args.strip then
            libs = libs..C_STRIP
        end
        -- @doc 'rules' explicitly providing input targets! 'inputs' is a synonym
        if args.inputs then args.rules = args.inputs end
        if args.rules then
            cr = args.rules
            -- @doc 'rules' may be a .deps file
            if type(cr) == 'string' then
                cr = rules_from_deps(cr)
            elseif is_simple_list(cr) then
                cr = depends(cr)
            end
            if src then warning('providing src= with explicit rules= is useless') end
        else
            if not src then src = {name} end
        end
        -- @doc 'export' this program exports its symbols
        if args.export then
            libs = libs..C_EXE_EXPORT
        end
    else
        args = {}
    end
    -- we can now create a rule object to compile files of this type to object files,
    -- using the appropriate compile command.
    local odir = args.odir
    if odir then
        -- @doc 'odir' set means we want a separate output directory. If a boolean,
        -- then we make a reasonably intelligent guess.
        if odir == true then
            odir = PREFIX..choose(DEBUG,'debug','release')
            if not isdir(odir) then lfs.mkdir(odir) end
        end
    end
    if not cr then
        -- generally a good idea for Unix shared libraries
        if ptype == 'dll' and CC ~= 'cl' and not WINDOWS then
            args.flags = (args.flags or '')..' -fPIC'
        end
        cr = _compile(args,deps,lang)
        cr.output_dir = odir
    end


    -- can now generate a target for generating the executable or library, unless
    -- this is just a group of files
    local t
    if ptype ~= 'group' then
        if not name then quit('no name provided for program') end
        -- @doc we may have explicit dependencies, but we are always dependent on the files
        -- generated by the compile rule.
        dependencies = choose(deps,depends(cr,deps),cr)
        local tname
        local btype = 'link'
        local link_prefix = ''
        if args and (args.shared or args.dll) then ptype = 'dll' end
        if ptype == 'exe' then
            tname = name..EXE_EXT
        elseif ptype == 'dll' then
            tname = name..DLL_EXT
            libs = libs..' '..C_LINK_DLL
            if C_LINK_PREFIX then link_prefix = C_LINK_PREFIX end
        elseif ptype == 'lib' then
            tname = LIB_PREFIX..name..LIB_EXT
            btype = 'lib'
        end
        -- @doc 'subsystem' with Windows, have to specify subsystem='windows' for pure GUI applications; ignored otherwise
        if subsystem and WINDOWS then
            libs = libs..' '..SUBSYSTEM..subsystem
        end
        local link_str = link_prefix..subst_all_but_basic(lang[btype])
        -- @doc conditional post-build step if a language defines a function 'post_build'
        -- that returns a string
        if btype == 'LINK' and lang.post_build then
            local post = lang.post_build(ptype,args)
            if post then link_str = link_str..' && '..post end
        end
        local target = tname

        -- @doc [target,odir] if the target looks like 'dir/name' then
        -- we make sure that 'dir' does exist. Otherwise, if `odir` exists it
        -- will be prepended.
        local tpath,tname = splitpath(target)
        if tname == '' then quit("target name cannot be empty, or a directory") end
        if tpath == '' then
            if odir then target = join(odir,target) end
        else
            lfs.mkdir(tpath)
        end

        t = new_target(target,dependencies,link_str,true)
        t.name = name
        t.libs = libs
        t.link = lang
        t.input = name..lang.obj_ext
        t.lua = args.lua
        t.ptype = ptype
        cr.parent = t
        t.compile_rule = cr
    end
    cr.filter = lang.filter
    cr.stdout = lang.stdout
    -- @doc  'src' we have been given a list of source files, without extension
    if src then
        local ext = args.ext or lang.ext
        src = expand_args(src,ext,args.recurse,args.base)
        if except then
            except = expand_args(except,ext,false,args.base)
            erase_list(src,except)
        end
        for f in list_(src) do cr(f) end
    end
    return t,cr
end

function lake.add_proglib (fname,lang,kind)
    lang[fname] = function (name,deps)
        return _program(kind,name,deps,lang)
    end
end

function lake.add_prog (lang) lake.add_proglib('program',lang,'exe') end
function lake.add_shared (lang) lake.add_proglib('shared',lang,'dll') end
function lake.add_library (lang) lake.add_proglib('library',lang,'lib') end

function lake.add_group (lang)
    lang.group = function (name,deps)
        local _,cr = _program('group',name,deps,lang)
        return cr
    end
end

for lang in list_ {c,c99,cpp} do
    lake.add_prog(lang)
    lake.add_shared(lang)
    lake.add_library(lang)
    lake.add_group(lang)
end

lake.add_prog(f)
lake.add_group(wresource)
lake.add_group(file)

function lake.program(fname,deps)
    local tp,name = lake.deduce_tool(fname)
    return tp.program(name,deps)
end

function lake.compile(args,deps)
    local tp,name = lake.deduce_tool(args.ext or args[1])
    append_table(args,tp.defaults)
    local rule = _compile(args,deps,tp)
    rule:add_target(name)
    return rule
end

function lake.shared(fname,deps)
    local tp,name = lake.deduce_tool(fname)
    return tp.shared(name,deps)
end

--- defines the default target for this lakefile
function default(...)
    if select('#',...) ~= 1 then quit("default() expects one argument!\nDid you use {}?") end
    local args = select(1,...)
    new_target('default',args,'',true)
end

--target = new_target -- global alias

target = {}
local tmt = utils.make_callable(target,new_target)
tmt.__index = function(obj,name)
    return function(...)
        return new_target(name,...)
    end
end

action = {}
local function  action_(name,action,...)
    local args
    if type(name) == 'function' then
        args = {action,...}
        action = name
        name = '*'
    else
        args = {...}
    end
    return new_target(name,nil,function() action(unpack(args)) end)
end
local amt = utils.make_callable(action,action_)
amt.__index = function(obj,name)
    return function(...)
        return action_(name,...)
    end
end

process_args()
