import os, streams, strutils, tables, times, zippy, zippy/internal, zippy/zippyerror

export zippyerror

const
  # TSUID   =  0o04000  # set UID on execution */
  # TSGID   =  0o02000  # set GID on execution */
  # TSVTX   =  0o01000  # reserved */
  #                     # file permissions */
  TUREAD  =  0o00400  # read by owner */
  TUWRITE =  0o00200  # write by owner */
  TUEXEC  =  0o00100  # execute/search by owner */
  TGREAD  =  0o00040  # read by group */
  TGWRITE =  0o00020  # write by group */
  TGEXEC  =  0o00010  # execute/search by group */
  TOREAD  =  0o00004  # read by other */
  TOWRITE =  0o00002  # write by other */
  TOEXEC  =  0o00001  # execute/search by other */

type
  EntryKind* = enum
    ekNormalFile = '0',
    ekDirectory = '5'

  TarballEntry* = object
    kind*: EntryKind
    contents*: string
    lastModified*: times.Time
    permissions*: set[FilePermission]

  Tarball* = ref object
    contents*: OrderedTable[string, TarballEntry]

  TarballFormat* = enum
    tfDetect, tfUncompressed, tfGzip

proc toPermissions(fileMode: int): set[FilePermission] =
  ## Convert from a fileMode integer to FilePermission
  when defined(windows):
    # Ignore file permissions on Windows, incl fpUserWrite so the file is
    # not read only.
    result.incl fpUserWrite
  else:
    if (fileMode and TUREAD) != 0: result.incl(fpUserRead)
    if (fileMode and TUWRITE) != 0: result.incl(fpUserWrite)
    if (fileMode and TUEXEC) != 0: result.incl(fpUserExec)
    if (fileMode and TGREAD) != 0: result.incl(fpGroupRead)
    if (fileMode and TGWRITE) != 0: result.incl(fpGroupWrite)
    if (fileMode and TGEXEC) != 0: result.incl(fpGroupExec)
    if (fileMode and TOREAD) != 0: result.incl(fpOthersRead)
    if (fileMode and TOWRITE) != 0: result.incl(fpOthersWrite)
    if (fileMode and TOEXEC) != 0: result.incl(fpOthersExec)

proc addDir(tarball: Tarball, base, relative: string) =
  if not (fileExists(base / relative) or dirExists(base / relative)):
    raise newException(
      ZippyError,
      "Path " & (base / relative) & " does not exist"
    )

  if relative.len > 0 and relative notin tarball.contents:
    tarball.contents[relative.toUnixPath()] = TarballEntry(kind: ekDirectory)

  for kind, path in walkDir(base / relative, relative = true):
    case kind:
    of pcFile:
      tarball.contents[(relative / path).toUnixPath()] = TarballEntry(
        kind: ekNormalFile,
        contents: readFile(base / relative / path),
        lastModified: getLastModificationTime(base / relative / path),
        permissions: getFilePermissions(base / relative / path),
      )
    of pcDir:
      tarball.addDir(base, relative / path)
    else:
      discard

proc addDir*(
  tarball: Tarball, dir: string
) {.raises: [IOError, OSError, ZippyError].} =
  ## Recursively adds all of the files and directories inside dir to tarball.
  if splitFile(dir).ext.len > 0:
    raise newException(
      ZippyError,
      "Error adding dir " & dir & " to tarball, appears to be a file?"
    )

  let (head, tail) = splitPath(dir)
  tarball.addDir(head, tail)

proc clear*(tarball: Tarball) {.raises: [].} =
  tarball.contents.clear()

template failEOF() =
  raise newException(
    ZippyError, "Attempted to read past end of file, corrupted tarball?"
  )

proc openStreamImpl(
  tarball: Tarball, stream: Stream, tarballFormat: TarballFormat
) =
  tarball.clear()

  proc trim(s: string): string =
    for i in 0 ..< s.len:
      if s[i] == '\0':
        return s[0 ..< i]
    s

  var data = stream.readAll() # TODO: actually treat as a stream

  var tarballFormat = tarballFormat
  if tarballFormat == tfDetect:
    if data[0] == 0x1F.char:
      case cast[uint8](data[1]):
      of 0x8B:
        tarballFormat = tfGzip
      else:
        raise newException(ZippyError, "Unsupported tarball format")
    else:
      tarballFormat = tfUncompressed

  case tarballFormat:
  of tfUncompressed:
    discard
  of tfGzip:
    data = uncompress(data, dfGzip)
  of tfDetect:
    discard # Handled above

  var pos: int
  while pos < data.len:
    if pos + 512 > data.len:
      failEOF()

    let
      header = data[pos ..< pos + 512]
      fileName = header[0 ..< 100].trim()

    pos += 512

    if fileName.len == 0:
      continue

    let
      fileSize =
        try:
          parseOctInt(header[124 .. 134])
        except ValueError:
          raise newException(
            ZippyError, "Unexpected error while opening tarball"
          )
      lastModified = try:
          parseOctInt(header[136 .. 146])
        except ValueError:
          raise newException(
            ZippyError, "Unexpected error while opening tarball"
          )
      typeFlag = header[156]
      fileMode = try:
          parseOctInt(header[100 ..< 107])
        except ValueError:
          raise newException(
            ZippyError, "Unexpected error while opening tarball (mode)"
          )
      fileNamePrefix =
        if header[257 ..< 263] == "ustar\0":
          header[345 ..< 500].trim()
        else:
          ""

    if pos + fileSize > data.len:
      failEOF()

    if typeFlag == '0' or typeFlag == '\0':
      tarball.contents[(fileNamePrefix / fileName).toUnixPath()] =
        TarballEntry(
          kind: ekNormalFile,
          contents: data[pos ..< pos + fileSize],
          lastModified: initTime(lastModified, 0),
          permissions: fileMode.toPermissions(),
        )
    elif typeFlag == '5':
      tarball.contents[(fileNamePrefix / fileName).toUnixPath()] =
        TarballEntry(
          kind: ekDirectory
        )

    # Move pos by fileSize, where fileSize is 512 byte aligned
    pos += (fileSize + 511) and not 511

when (NimMajor, NimMinor, NimPatch) >= (1, 4, 0):
  proc open*(
    tarball: Tarball, stream: Stream, tarballFormat = tfDetect
  ) {.raises: [IOError, OSError, ZippyError].} =
    ## Opens the zip archive from a stream and reads its contents into
    ## archive.contents (clears any existing archive.contents entries).
    openStreamImpl(tarball, stream, tarballFormat)
else:
  proc open*(
    tarball: Tarball, stream: Stream, tarballFormat = tfDetect
  ) {.raises: [Defect, IOError, OSError, ZippyError].} =
    ## Opens the zip archive from a stream and reads its contents into
    ## archive.contents (clears any existing archive.contents entries).
    openStreamImpl(tarball, stream, tarballFormat)

proc openPathImpl*(tarball: Tarball, path: string) =
  let
    stream = newStringStream(readFile(path))
    ext = splitFile(path).ext
  case ext:
  of ".tar":
    tarball.open(stream, tfUncompressed)
  of ".gz", ".taz", ".tgz":
    tarball.open(stream, tfGzip)
  else:
    raise newException(ZippyError, "Unsupported tarball extension " & ext)

when (NimMajor, NimMinor, NimPatch) >= (1, 4, 0):
  proc open*(
    tarball: Tarball, path: string
  ) {.raises: [IOError, OSError, ZippyError].} =
    ## Opens the tarball file located at path and reads its contents into
    ## tarball.contents (clears any existing tarball.contents entries).
    ## Supports .tar, .tar.gz, .taz and .tgz file extensions.
    openPathImpl(tarball, path)
else:
  proc open*(
    tarball: Tarball, path: string
  ) {.raises: [Defect, IOError, OSError, ZippyError].} =
    ## Opens the tarball file located at path and reads its contents into
    ## tarball.contents (clears any existing tarball.contents entries).
    ## Supports .tar, .tar.gz, .taz and .tgz file extensions.
    openPathImpl(tarball, path)

proc writeTarball*(
  tarball: Tarball, path: string
) {.raises: [IOError, ZippyError].} =
  ## Writes tarball.contents to a tarball file at path. Uses the path's file
  ## extension to determine the tarball format. Supports .tar, .tar.gz, .taz
  ## and .tgz file extensions.

  if tarball.contents.len == 0:
    raise newException(ZippyError, "Tarball has no contents")

  var data = ""

  for path, entry in tarball.contents:
    let (head, tail) = splitPath(path)

    if head.len >= 155:
      raise newException(
        ZippyError,
        "File path " & head & " too long, must be < 155 characters"
      )
    if tail.len >= 100:
      raise newException(
        ZippyError,
        "File name " & tail & " too long, must be < 100 characters"
      )

    var header = newStringOfCap(512)
    header.add(tail)
    header.setLen(100)
    header.add("000777 \0") # File mode
    header.add(toOct(0, 6) & " \0") # Owner's numeric user ID
    header.add(toOct(0, 6) & " \0") # Group's numeric user ID
    header.add(toOct(entry.contents.len, 11) & ' ') # File size
    header.add(toOct(entry.lastModified.toUnix(), 11) & ' ') # Last modified time
    header.add("        ") # Empty checksum for now
    header.setLen(156)
    header.add(ord(entry.kind).char)
    header.setLen(257)
    header.add("ustar\0") # UStar indicator
    header.add(toOct(0, 2)) # UStar version
    header.setLen(329)
    header.add(toOct(0, 6) & "\0 ") # Device major number
    header.add(toOct(0, 6) & "\0 ") # Device minor number
    header.add(head)
    header.setLen(512)

    var checksum: int
    for i in 0 ..< header.len:
      checksum += header[i].int

    let checksumStr = toOct(checksum, 6) & '\0'
    for i in 0 ..< checksumStr.len:
      header[148 + i] = checksumStr[i]

    data.add(header)
    data.add(entry.contents)
    data.setLen((data.len + 511) and not 511) # 512 byte aligned

  data.setLen(data.len + 1024) # Two consecutive zero-filled records at end

  let ext = splitFile(path).ext
  case ext:
  of ".tar":
    writeFile(path, data)
  of ".gz", ".taz", ".tgz":
    # Tarball compressed using gzip
    writeFile(path, compress(data, DefaultCompression, dfGzip))
  else:
    raise newException(ZippyError, "Unsupported tarball extension " & ext)

proc extractAll*(
  tarball: Tarball, dest: string
) {.raises: [IOError, OSError, ZippyError].} =
  ## Extracts the files stored in tarball to the destination directory.
  ## The path to the destination directory must exist.
  ## The destination directory itself must not exist (it is not overwitten).
  if dirExists(dest):
    raise newException(
      ZippyError, "Destination " & dest & " already exists"
    )

  let (head, tail) = splitPath(dest)
  if tail != "" and not dirExists(head):
    raise newException(
      ZippyError, "Path to destination " & dest & " does not exist"
    )

  # Ensure we only raise exceptions we handle below
  proc writeContents(
    tarball: Tarball, dest: string
  ) {.raises: [IOError, OSError, ZippyError].} =
    for path, entry in tarball.contents:
      if path.isAbsolute():
        raise newException(
          ZippyError,
          "Extracting absolute paths is not supported (" & path & ")"
        )
      if path.startsWith("../") or path.startsWith(r"..\"):
        raise newException(
          ZippyError,
          "Extracting paths starting with `..` is not supported (" & path & ")"
        )
      if "/../" in path or r"\..\" in path:
        raise newException(
          ZippyError,
          "Extracting paths containing `/../` is not supported (" & path & ")"
        )

      case entry.kind:
      of ekNormalFile:
        createDir(dest / splitFile(path).dir)
        writeFile(dest / path, entry.contents)
        if entry.lastModified > Time():
          setLastModificationTime(dest / path, entry.lastModified)
        setFilePermissions(dest / path, entry.permissions)
      of ekDirectory:
        createDir(dest / path)

  try:
    tarball.writeContents(dest)
  except IOError as e:
    removeDir(dest)
    raise e
  except OSError as e:
    removeDir(dest)
    raise e
  except ZippyError as e:
    removeDir(dest)
    raise e

when (NimMajor, NimMinor, NimPatch) >= (1, 4, 0):
  proc extractAll*(
    tarPath, dest: string
  ) {.raises: [IOError, OSError, ZippyError].} =
    ## Extracts the files in the tarball located at tarPath into the destination
    ## directory. Supports .tar, .tar.gz, .taz and .tgz file extensions.
    let tarball = Tarball()
    tarball.open(tarPath)
    tarball.extractAll(dest)
else:
  proc extractAll*(
    tarPath, dest: string
  ) {.raises: [Defect, IOError, OSError, ZippyError].} =
    ## Extracts the files in the tarball located at tarPath into the destination
    ## directory. Supports .tar, .tar.gz, .taz and .tgz file extensions.
    let tarball = Tarball()
    tarball.open(tarPath)
    tarball.extractAll(dest)

proc createTarball*(
  source, dest: string
) {.raises: [IOError, OSError, ZippyError].} =
  ## Creates a tarball containing all of the files and directories inside
  ## source and writes the tarball file to dest. Uses the dest path's file
  ## extension to determine the tarball format. Supports .tar, .tar.gz, .taz
  ## and .tgz file extensions.
  let tarball = Tarball()
  tarball.addDir(source)
  tarball.writeTarball(dest)
