import capnp/util
import capnp/bitseq
import collections

type SomeInt = int8|int16|int32|int64|uint8|uint16|uint32|uint64

const
  bufferLimit = 64 * 1024 * 1024
  stackLimit = 128

type Unpacker* = ref object
  readLimit: int
  stackLimit: int
  segments: seq[string]
  currentSegment: int

proc parseStruct*(self: Unpacker, offset: int, parseOffset=true): tuple[offset: int, dataLength: int, pointerCount: int]

template deferRestoreStackLimit(): stmt =
  let old = self.stackLimit
  defer: self.stackLimit = old

proc decreaseLimit(self: Unpacker, size: int) =
  self.stackLimit -= 1
  self.readLimit -= size
  if self.stackLimit < 0:
    raise newException(CapnpFormatError, "recursion (stack) limit reached")
  if self.readLimit < 0:
    raise newException(CapnpFormatError, "recursion (read) limit reached")

proc newUnpackerFlat*(buffer: string): Unpacker =
  new(result)
  result.readLimit = bufferLimit
  result.stackLimit = stackLimit
  result.segments = @[buffer]
  result.currentSegment = 0

proc buffer*(self: Unpacker): string {.inline.} =
  self.segments[self.currentSegment]

proc parseMultiSegment(buffer: string): seq[string] =
  let count = unpack(buffer, 0, uint32)
  var lengths: seq[int] = @[]
  var index = 4
  for i in 0..count:
    lengths.add(unpack(buffer, index, uint32).int * 8)
    index += 4

  if index mod 8 != 0: index += 4

  result = @[]
  for length in lengths:
    if length < 0 or length > bufferLimit or (index + length) > buffer.len:
      raise newException(CapnpFormatError, "truncated multisegment")
    var s = buffer[index..<(index + length)]
    s.shallow
    result.add s
    index += length

proc newUnpacker*(buffer: string): Unpacker =
  new(result)
  result.readLimit = bufferLimit
  result.stackLimit = stackLimit
  result.segments = parseMultiSegment(buffer)
  result.currentSegment = 0

proc unpackScalar*[T: SomeInt](self: Unpacker, offset: int, typ: typedesc[T], defaultValue: T=0): T =
  return unpack(self.buffer, offset, typ) xor defaultValue

proc unpackScalar*(self: Unpacker, offset: int, typ: typedesc[float32], defaultValue: float32=0): float32 =
  return cast[float32](unpackScalar(self, offset, uint32, cast[uint32](defaultValue)))

proc unpackScalar*(self: Unpacker, offset: int, typ: typedesc[float64], defaultValue: float64=0): float64 =
  return cast[float64](unpackScalar(self, offset, uint64, cast[uint64](defaultValue)))

proc unpackScalar*[T: enum](self: Unpacker, offset: int, typ: typedesc[T], defaultValue: T=T.low): T =
  return self.unpackScalar(offset, uint16, defaultValue.uint16).T

proc unpackBool*(self: Unpacker, baseOffset: int, bitOffset: int, defaultValue: bool): bool =
  let offset = baseOffset + bitOffset div 8
  let bit = bitOffset mod 8
  let byteValue = unpack(buffer(self), offset, uint8)
  return ((byteValue and (1 shl bit).uint8) != 0) xor defaultValue

proc unpackOffsetSigned(num: int): int =
  if (num and (1 shl 29)) != 0:
    return (num and ((1 shl 29) - 1)) - (1 shl 29)
  else:
    return num

assert unpackOffsetSigned(1073741823) == -1

proc unpackInterSegment[T](self: Unpacker, pointer: uint64, typ: typedesc[T]): T =
  mixin unpackPointer

  let typeTag = extractBits(pointer, 0, bits=2)
  if typeTag != 2:
    raise newException(CapnpFormatError, "expected intersegment pointer")

  let oneWord = extractBits(pointer, 2, bits=1) == 0
  let offset = extractBits(pointer, 3, bits=29) * 8
  let newSegment = extractBits(pointer, 32, bits=32)
  let oldSegment = self.currentSegment


  self.currentSegment = newSegment
  defer: self.currentSegment = oldSegment

  if oneWord:
    return self.unpackPointer(offset, typ)
  else:
    raise newException(CapnpFormatError, "two-word pointers not implemented")

proc unpackPointerList[T](self: Unpacker, typ: typedesc[T], target: typedesc[seq[T]], bodyOffset: int, itemSizeTag: int, itemNumber: int): seq[T] =
  mixin unpackPointer
  var itemSize: int

  if itemSizeTag != 6:
    raise newException(CapnpFormatError, "bad item size")

  var target = newSeq[T](itemNumber)

  if itemNumber > bufferLimit or itemNumber * 8 > bufferLimit:
    raise newException(CapnpFormatError, "list too big")

  let listSize = itemNumber * 8

  if bodyOffset < 0 or listSize < 0 or bodyOffset >= self.buffer.len or bodyOffset + listSize > self.buffer.len:
    raise newException(CapnpFormatError, "index error")

  deferRestoreStackLimit
  self.decreaseLimit(listSize)

  for i in 0..<itemNumber:
    target[i] = unpackPointer(self, bodyOffset + i * 8, typ)

  return target

proc unpackScalarList[T, Target](self: Unpacker, typ: typedesc[T], target: typedesc[Target], bodyOffset: int, itemSizeTag: int, itemNumber: int): Target =
  var itemSize: int

  case itemSizeTag:
  of 2: itemSize = 1
  of 3: itemSize = 2
  of 4: itemSize = 4
  of 5: itemSize = 8
  else: raise newException(CapnpFormatError, "bad item size")

  if sizeof(T) != itemSize:
    raise newException(CapnpFormatError, "bad item size")

  var target: Target

  when Target is seq:
    target = newSeq[T](itemNumber)
  else:
    when not (T is byte): {.error: "bad T for string result".}
    target = newString(itemNumber)

  if itemNumber > bufferLimit or itemNumber * sizeof(T) > bufferLimit:
    raise newException(CapnpFormatError, "list too big")

  let listSize = itemNumber * sizeof(T)

  if bodyOffset < 0 or listSize < 0 or bodyOffset > self.buffer.len or bodyOffset + listSize > self.buffer.len:
    raise newException(CapnpFormatError, "index error")

  var buffer = self.buffer
  copyMem(addr target[0],
          addr buffer[bodyOffset], listSize)

  deferRestoreStackLimit
  self.decreaseLimit(listSize)

  when cpuEndian == bigEndian:
    {.error: "TODO: swap items on list".}

  return target

proc unpackCompositeList[T](self: Unpacker, typ: typedesc[T], bodyOffset: int, itemSizeTag: int, wordCount: int): seq[T] =
  if itemSizeTag != 7:
    raise newException(CapnpFormatError, "expected composite list, got scalar list")

  if wordCount > bufferLimit:
    raise newException(CapnpFormatError, "composite list too big")

  deferRestoreStackLimit
  self.decreaseLimit(wordCount * 8)

  let s = self.parseStruct(bodyOffset, parseOffset=false)
  let itemCount = s.offset
  let itemSize = (s.dataLength + 8 * s.pointerCount)

  if itemCount > bufferLimit or itemSize > bufferLimit:
    raise newException(CapnpFormatError, "composite list too big")

  if itemSize == 0:
    raise newException(CapnpFormatError, "empty composite list")

  if itemSize * itemCount != wordCount * 8 or ((wordCount * 8 div itemSize) != itemCount):
    raise newException(CapnpFormatError, "composite list size mismatch")

  if bodyOffset + 8 + itemSize * itemCount > self.buffer.len:
    raise newException(CapnpFormatError, "index error")

  mixin capnpUnpackStructImpl
  result = newSeq[T](itemCount)

  for i in 0..<itemCount:
    let itemOffset = bodyOffset + 8 + itemSize * i
    result[i] = capnpUnpackStructImpl(self, itemOffset, s.dataLength, s.pointerCount, typ)

proc unpackListImpl[T, Target](self: Unpacker, offset: int, typ: typedesc[T], target: typedesc[Target]): Target =
  let buffer = self.buffer

  let pointer = unpack(buffer, offset, uint64)
  let typeTag = extractBits(pointer, 0, bits=2)
  if typeTag == 2:
    return unpackInterSegment(self, pointer, Target)
  if pointer == 0:
    return nil

  if typeTag != 1:
    raise newException(CapnpFormatError, "expected list, found " & $typeTag)

  let bodyOffset = extractBits(pointer, 2, bits=30).unpackOffsetSigned * 8 + offset + 8
  let itemSizeTag = extractBits(pointer, 32, bits=3)
  let itemNumber = extractBits(pointer, 35, bits=29)

  when typ is bool: # bitseq
    if itemSizeTag != 1:
      raise newException(CapnpFormatError, "expected bitseq")
    return newBitSeq(buffer, offset, itemSize)

  when typ is CapnpScalar:
    return unpackScalarList(self, typ, target, bodyOffset, itemSizeTag, itemNumber)
  elif typ is seq|string:
    return unpackPointerList(self, typ, target, bodyOffset, itemSizeTag, itemNumber)
  else:
    return unpackCompositeList(self, typ, bodyOffset, itemSizeTag, itemNumber)

proc unpackList*[T](self: Unpacker, offset: int, target: typedesc[seq[T]]): seq[T] =
  return self.unpackListImpl(offset, T, seq[T])

proc unpackList*(self: Unpacker, offset: int, target: typedesc[string]): string =
  return self.unpackListImpl(offset, byte, string)

proc parseStruct(self: Unpacker, offset: int, parseOffset=true): tuple[offset: int, dataLength: int, pointerCount: int] =
  let pointer = unpack(self.buffer, offset, uint64)
  let typ = extractBits(pointer, 0, bits=2)

  if pointer == 0:
    return (0, 0, 0)

  if typ != 0:
    raise newException(CapnpFormatError, "expected struct, found " & $typ)

  result.offset = extractBits(pointer, 2, bits=30).unpackOffsetSigned
  let dataWords = extractBits(pointer, 32, bits=16)
  if dataWords > int(bufferLimit / 8):
    raise newException(CapnpFormatError, "struct too big")

  result.dataLength = dataWords * 8
  result.pointerCount = extractBits(pointer, 48, bits=16)

  if result.pointerCount > bufferLimit:
    raise newException(CapnpFormatError, "struct too big")

  if parseOffset:
    result.offset *= 8
    result.offset += offset + 8

    if result.offset < 0 or result.offset >= self.buffer.len or result.offset + result.dataLength > self.buffer.len or result.offset + result.dataLength + result.pointerCount * 8 > self.buffer.len:
      raise newException(CapnpFormatError, "index error")

proc unpackStruct*[T](self: Unpacker, offset: int, typ: typedesc[T]): T =
  let pointer = unpack(self.buffer, offset, uint64)
  if extractBits(pointer, 0, bits=2) == 2:
    return unpackInterSegment(self, pointer, T)
  
  mixin capnpUnpackStructImpl
  let s = parseStruct(self, offset)
  deferRestoreStackLimit
  self.decreaseLimit(s.pointerCount * 8 + s.pointerCount)
  return capnpUnpackStructImpl(self, s.offset, s.dataLength, s.pointerCount, typ)

import typetraits

proc unpackPointer*[T](self: Unpacker, offset: int, typ: typedesc[T]): T =
  when typ is seq or typ is string:
    return unpackList(self, offset, typ)
  else:
    return unpackStruct(self, offset, typ)

proc postprocessText(t: string): string =
  if t == nil: return nil
  if t.len == 0 or t[^1] != '\0':
    raise newException(CapnpFormatError, "text without trailing zero")
  return t[0..(t.len-2)]

proc postprocessText[T](t: seq[T]): seq[T] =
  if t == nil: return nil
  else: return t.map(x => postprocessText(x)).toSeq

proc unpackText*[T](self: Unpacker, offset: int, typ: typedesc[T]): T =
  # strip trailing zero
  return unpackPointer(self, offset, T).postprocessText
