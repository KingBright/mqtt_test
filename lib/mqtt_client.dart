import 'dart:convert';
import 'dart:developer';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// A socket connection to a mqtt server
class Connection {
  Socket? _socket;

  // create a pending message list
  final List<Uint8List> _pending = [];

  // callback
  late void Function(Uint8List data)? _callback;

  Connection connect(String host, int port) {
    Socket.connect(host, port).then((socket) {
      _socket = socket;

      // listen to the socket
      socket.listen(_onMessage, onError: _onError, onDone: _onDone);

      // send pending messages, and remove them from pending list
      while (_pending.isNotEmpty) {
        var data = _pending.removeAt(0);
        sendMessage(data);
      }
    }).whenComplete(() {
      print('complete');
    }).then((value) {
      print('then: $value');
    }).catchError((error) {
      print('error: $error');
    });

    return this;
  }

  // set callback
  Connection setCallback(void Function(Uint8List data) callback) {
    _callback = callback;
    return this;
  }

  void _onMessage(Uint8List data) {
    print('receive message :$data');
    // if _callback is not initialized, do nothing
    if (_callback == null) {
      return;
    }
    _callback!(data);
  }

  void _onError(Object error) {
    print('error: $error');
  }

  void _onDone() {
    print('done');
  }

  void sendMessage(Uint8List data) {
    if (_socket == null) {
      // put data to a pending list
      _pending.add(data);
      return;
    }

    print('send data, total length: ${data.length}');
    debug(data);
    _socket!.add(data);
  }
}

// A data packet for mqtt protocol
class DataPacket {
  BytesBuilder builder = BytesBuilder(copy: true);

  int offset = 0;

  DataPacket();

  DataPacket.fromData(Uint8List data) {
    builder.add(data);
  }

  void writeByte(int byte) {
    builder.addByte(byte);
  }

  void writeBytes(Uint8List bytes) {
    bytes.forEach(writeByte);
  }

  Uint8List toBuffer() {
    return builder.toBytes();
  }

  /// 写入字符串时，需要先写入其长度，字符串长度最大为2字节
  void writeString(String str) {
    // convert str to a Uint8List
    var bytes = Uint8List.fromList(str.codeUnits);

    int length = bytes.length;
    writeShort(length);
    writeBytes(bytes);
  }

  //writeShort
  void writeShort(int length) {
    writeByte(length >> 8);
    writeByte(length & 0xff);
  }

  //readShort
  int readShort() {
    var high = readByte();
    var low = readByte();
    return (high << 8) + low;
  }

  //readString
  String readString() {
    var length = readShort();
    var bytes = readBytes(length);
    var str = String.fromCharCodes(bytes);
    return str;
  }

  // read a byte
  int readByte() {
    if (getLength() < offset) {
      print('offset: $offset, length: ${getLength()}');
      throw Exception('length exceeded.');
    }
    var byte = builder.toBytes()[offset];
    offset += 1;
    return byte;
  }

  // read string array
  List<String> readStringArray() {
    var length = readShort();
    var list = <String>[];
    for (int i = 0; i < length; i++) {
      list.add(readString());
    }
    return list;
  }

  // read bytes
  Uint8List readBytes(int length) {
    var bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = readByte();
    }
    return bytes;
  }

  void writeDataPacket(DataPacket packet) {
    var bytes = packet.toBuffer();
    writeBytes(bytes);
  }

  DataPacket subPacket(int length) {
    var packet = DataPacket();
    packet.writeBytes(readBytes(length));
    return packet;
  }

  // get data length
  int getLength() {
    return builder.length;
  }

  // copy
  DataPacket copy() {
    var packet = DataPacket();
    packet.writeBytes(toBuffer());
    return packet;
  }
}

// The base class for all mqtt data.
abstract class DataBase {
  late DataPacket dataPacket;

  DataBase.fromData(this.dataPacket);
  DataBase.create() {
    dataPacket = DataPacket();
  }

  int readByte() {
    return dataPacket.readByte();
  }

  Uint8List readBytes(int length) {
    var bytes = dataPacket.readBytes(length);
    return bytes;
  }

  String readString() {
    return dataPacket.readString();
  }

  //read the rest
  Uint8List readRest() {
    return dataPacket.readBytes(dataPacket.getLength() - dataPacket.offset);
  }

  //read short
  int readShort() {
    return dataPacket.readShort();
  }

  void writeByte(int data) {
    dataPacket.writeByte(data);
  }

  void writeBytes(Uint8List data) {
    dataPacket.writeBytes(data);
  }

  void writeString(String data) {
    dataPacket.writeString(data);
  }

  void writeShort(int data) {
    dataPacket.writeShort(data);
  }

  void writeDataPacket(DataPacket packet) {
    if (packet.getLength() == 0) {
      print('data is null');
      return;
    }
    dataPacket.writeDataPacket(packet);
  }

  // sub packet
  DataPacket subPacket(int length) {
    return dataPacket.subPacket(length);
  }

  // get data packet
  DataPacket getDataPacket() {
    return dataPacket;
  }

  // to List<int>
  Uint8List toBuffer() {
    return dataPacket.toBuffer();
  }

  // get data length
  int getLength() {
    return dataPacket.getLength();
  }

  void parse();
  void generate();
}

abstract class Header extends DataBase {
  Header.create() : super.create();
  Header.fromData(DataPacket dataPacket) : super.fromData(dataPacket);
}

// The fix header for mqtt data.
class FixedHeader extends Header {
  Map types = {
    'typeConn': 1,
    'typeConnAck': 2,
    'typePub': 3,
    'typePubAck': 4,
    'typePubRec': 5,
    'typePubRel': 6,
    'typePubComp': 7,
    'typeSub': 8,
    'typeSubAck': 9,
    'typeUnsub': 10,
    'typeUnsubAck': 11,
    'typePing': 12,
    'typePingAck': 13,
    'typeDisconn': 14,
  };

  static const int flagDup = 8;

  // totally 2 bits, 0 for qos0 1 for qos1 2 for qos2
  static const int flagQos0 = 0;
  static const int flagQos1 = 2;
  static const int flagQos2 = 4;

  static const int flagRetain = 1;
  static const int flagLengthRemain = 128;

  late String type;
  late bool duplicated;
  late int qosLevel = 0;
  late bool retain;

  late int remainDataLength;

  FixedHeader.create() : super.create();
  FixedHeader.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // first byte for type & flag
    var controlField = readByte();
    print('control field : $controlField');
    var ret = types.entries.firstWhere((element) {
      return controlField >> 4 == element.value;
    });
    type = ret.key;

    duplicated = (controlField & flagDup) == flagDup;

    if (controlField & flagQos0 == flagQos0) {
      qosLevel = 0;
    } else if (controlField & flagQos1 == flagQos1) {
      qosLevel = 1;
    } else if (controlField & flagQos2 == flagQos2) {
      qosLevel = 2;
    }

    retain = (controlField & flagRetain) == flagRetain;

    int readLength([int level = 1, int length = 0]) {
      var byte = readByte();

      length = length | (byte & 127);
      // if has next byte
      if (byte & flagLengthRemain == flagLengthRemain && level < 4) {
        return readLength(level + 1, length << 7);
      }
      return length;
    }

    remainDataLength = readLength();

    print('control field: $controlField, remain length: $remainDataLength');
  }

  void setTypeAndFlag(String type,
      [bool duplicated = false, int qosLevel = 0, bool retain = false]) {
    if (types.containsKey(type)) {
      this.type = type;
    } else {
      throw Exception('not supported type');
    }
    this.duplicated = duplicated;
    this.qosLevel = qosLevel;
    this.retain = retain;
  }

  void _setDataLength(int dataLength) {
    var bytesNeeded = Util.lengthToBytes(dataLength);
    print('bytes needed for remaining data($dataLength): $bytesNeeded');
    if (bytesNeeded >= 4) {
      writeByte(dataLength >> 21 & 127 | 128);
    }
    if (bytesNeeded >= 3) {
      writeByte(dataLength >> 14 & 127 | 128);
    }
    if (bytesNeeded >= 2) {
      writeByte(dataLength >> 7 & 127 | 128);
    }
    if (bytesNeeded >= 1) {
      print(dataLength & 127);
      writeByte(dataLength & 127);
    }
  }

  //get type
  String getType() {
    return type;
  }

  @override
  void generate() {
    // write data to dataPacket
    var byte = types[type] << 4;
    if (duplicated) {
      byte |= flagDup;
    }
    if (qosLevel == 1) {
      byte |= flagQos1;
    } else if (qosLevel == 2) {
      byte |= flagQos2;
    }
    if (retain) {
      byte |= retain;
    }

    // write control field, 1 byte
    writeByte(byte);

    // write data length, convert remaining data length to bytes
    _setDataLength(remainDataLength);

    print('control field: $byte, remain length: $remainDataLength');
  }

  void setRemainingLength(int length) {
    remainDataLength = length;
  }
}

abstract class VariableHeader extends Header {
  VariableHeader.create() : super.create();
  VariableHeader.fromData(DataPacket dataPacket) : super.fromData(dataPacket);
}

class Payload extends DataBase {
  Payload.create() : super.create();
  Payload.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {}

  @override
  void generate() {}
}

class ConnectVariableHeader extends VariableHeader {
  // protocol name
  String protocolName = 'MQTT';
  // protocol level
  int protocolLevel = 4;
  // connect flag
  bool connectFlagReserved = false;
  bool connectFlagCleanSession = false;
  bool connectFlagWillFlag = false;
  int connectFlagWillQos = 0;
  bool connectFlagWillRetain = false;
  bool connectFlagPasswordFlag = true;
  bool connectFlagUserNameFlag = true;
  // keep alive
  int keepAlive = 0;

  ConnectVariableHeader.create() : super.create();
  ConnectVariableHeader.fromData(DataPacket dataPacket)
      : super.fromData(dataPacket);

  @override
  void parse() {
    // parse protocol name
    protocolName = readString();

    // parse protocol level
    protocolLevel = readByte();

    // parse connect flag
    var connectFlag = readByte();
    connectFlagReserved = (connectFlag & 00000001) == 00000001;
    connectFlagCleanSession = (connectFlag & 00000010) == 00000010;
    connectFlagWillFlag = (connectFlag & 00000100) == 00000100;
    connectFlagWillQos = (connectFlag & 00011000) >> 3;
    connectFlagWillRetain = (connectFlag & 00100000) == 00100000;
    connectFlagPasswordFlag = (connectFlag & 01000000) == 01000000;
    connectFlagUserNameFlag = (connectFlag & 10000000) == 10000000;

    // parse keep alive
    keepAlive = readShort();
  }

  @override
  void generate() {
    // generate protocol name
    writeString(protocolName);

    // generate protocol level
    writeByte(protocolLevel);

    // generate connect flag
    var connectFlag = 0;
    if (connectFlagCleanSession) {
      connectFlag |= 00000010;
    }
    if (connectFlagWillFlag) {
      connectFlag |= 00000100;
    }
    if (connectFlagWillQos == 1) {
      connectFlag |= 00001000;
    } else if (connectFlagWillQos == 2) {
      connectFlag |= 00010000;
    } else if (connectFlagWillQos == 3) {
      connectFlag |= 00011000;
    }
    if (connectFlagWillRetain) {
      connectFlag |= 00100000;
    }
    if (connectFlagPasswordFlag) {
      connectFlag |= 01000000;
    }
    if (connectFlagUserNameFlag) {
      connectFlag |= 10000000;
    }
    writeByte(connectFlag);

    // generate keep alive
    writeShort(keepAlive);
  }
}

class ConnectPayload extends Payload {
  // client identifier
  String clientIdentifier = '812f6c74ecbb4c8b9c4418a671ad7312';
  // will topic
  String willTopic = '';
  // will message
  String willMessage = '';
  // user name
  String userName = 'jinliang';
  // password
  String password = 'jinliang123';

  ConnectPayload.create() : super.create();
  ConnectPayload.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse client identifier
    clientIdentifier = readString();

    // // parse will topic
    // willTopic = readString();

    // // parse will message
    // willMessage = readString();

    // parse user name
    userName = readString();

    // parse password
    password = readString();
  }

  @override
  void generate() {
    // generate client identifier
    writeString(clientIdentifier);

    // // generate will topic
    // writeString(willTopic);

    // // generate will message
    // writeString(willMessage);

    // generate user name
    writeString(userName);

    // generate password
    writeString(password);
  }
}

abstract class MqttMessage extends DataBase {
  MqttMessage.create() : super.create();
  MqttMessage.fromData(DataPacket dataPacket) : super.fromData(dataPacket);
}

class Util {
  static int lengthToBytes(int length) {
    if (length < 127) {
      return 1;
    } else if (length < 16383) {
      return 2;
    } else if (length < 2097151) {
      return 3;
    } else if (length < 268435455) {
      return 4;
    } else {
      throw Exception('Length exceceds');
    }
  }

  static int bytesToLength(int bytesNum) {
    if (bytesNum == 1) {
      return 127;
    } else if (bytesNum == 2) {
      return 16383;
    } else if (bytesNum == 3) {
      return 2097151;
    } else if (bytesNum == 4) {
      return 268435455;
    } else {
      throw Exception('Length exceceds');
    }
  }
}

class ConnectMessage extends MqttMessage {
  ConnectMessage.create() : super.create();
  ConnectMessage.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse fixed header
    var fixedHeader = FixedHeader.fromData(dataPacket);
    fixedHeader.parse();

    // parse variable header
    var connectVariableHeader = ConnectVariableHeader.fromData(dataPacket);
    connectVariableHeader.parse();

    // parse payload
    var connectPayload = ConnectPayload.fromData(dataPacket);
    connectPayload.parse();
  }

  @override
  void generate() {
    var connectVariableHeader = ConnectVariableHeader.create();
    connectVariableHeader.generate();
    var connectPayload = ConnectPayload.create();
    connectPayload.generate();

    // write all to message
    // fixed header 2 bytes + content length + variable header + payload
    // create fixed header
    var fixedHeader = FixedHeader.create();
    fixedHeader.setTypeAndFlag('typeConn');
    fixedHeader.setRemainingLength(
        connectVariableHeader.getLength() + connectPayload.getLength());
    fixedHeader.generate();

    // write fixed header
    writeDataPacket(fixedHeader.dataPacket);

    // write variable header
    writeDataPacket(connectVariableHeader.dataPacket);
    // write payload
    writeDataPacket(connectPayload.dataPacket);
  }
}

// create a message representing the connect ack message
class ConnectAckMessage extends MqttMessage {
  ConnectAckMessage.create() : super.create();
  ConnectAckMessage.fromData(DataPacket dataPacket)
      : super.fromData(dataPacket);

  @override
  void parse() {
    // parse fixed header
    var fixedHeader = FixedHeader.fromData(dataPacket);
    fixedHeader.parse();

    // parse variable header
    var connectAckVariableHeader =
        ConnectAckVariableHeader.fromData(dataPacket);
    connectAckVariableHeader.parse();
  }

  @override
  void generate() {
    // create variable header
    var connectAckVariableHeader = ConnectAckVariableHeader.create();
    connectAckVariableHeader.generate();

    // create fixed header
    var fixedHeader = FixedHeader.create();
    fixedHeader.setTypeAndFlag('typeConnAck');
    fixedHeader.setRemainingLength(connectAckVariableHeader.getLength());
    fixedHeader.generate();

    // write fixed header
    writeDataPacket(fixedHeader.dataPacket);

    // write variable header
    writeDataPacket(connectAckVariableHeader.dataPacket);
  }
}

class ConnectAckVariableHeader extends VariableHeader {
  int acknowledgeFlags = 0;
  // connect ack return code
  int connectAckReturnCode = 0;

  ConnectAckVariableHeader.create() : super.create();
  ConnectAckVariableHeader.fromData(DataPacket dataPacket)
      : super.fromData(dataPacket);

  @override
  void parse() {
    // parse acknowledge flags
    var acknowledgeFlags = readByte();
    // parse the last bit of acknowledge flags
    var sessionPresent = acknowledgeFlags & 0x01;
    print('session present: $sessionPresent');

    // parse connect ack return code
    connectAckReturnCode = readByte();
    // make return code readable with enums

    print('connect ack return code: $connectAckReturnCode');
  }

  @override
  void generate() {
    // generate connect ack return code
    writeByte(connectAckReturnCode);
  }
}

// a util function to parse server data to specific message
MqttMessage parseMessage(Uint8List data) {
  var dataPacket = DataPacket.fromData(data);
  var fixedHeader = FixedHeader.fromData(dataPacket);
  fixedHeader.parse();
  dataPacket = dataPacket.copy();

  var type = fixedHeader.getType();
  print('message type: $type');
  if (type == 'typeConnAck') {
    return ConnectAckMessage.fromData(dataPacket);
  } else if (type == 'typePub') {
    return PublishMessage.fromData(dataPacket);
  }
  // else if (type == 'typePubAck') {
  //   return PubAckMessage.fromData(dataPacket);
  // } else if (type == 'typePubRec') {
  //   return PubRecMessage.fromData(dataPacket);
  // } else if (type == 'typePubRel') {
  //   return PubRelMessage.fromData(dataPacket);
  // } else if (type == 'typePubComp') {
  //   return PubCompMessage.fromData(dataPacket);
  else if (type == 'typeSubAck') {
    return SubAckMessage.fromData(dataPacket);
  }
  // else if (type == 'typeUnsubAck') {
  //   return UnsubAckMessage.fromData(dataPacket);
  // } else if (type == 'typePingResp') {
  //   return PingRespMessage.fromData(dataPacket);
  // }
  else {
    throw Exception('Unknown message type');
  }
}

// create PublishMessage class
class PublishMessage extends MqttMessage {
  PublishMessage.create() : super.create();
  PublishMessage.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse fixed header
    var fixedHeader = FixedHeader.fromData(dataPacket);
    fixedHeader.parse();

    // parse variable header
    var publishVariableHeader = PublishVariableHeader.fromData(dataPacket);
    publishVariableHeader.parse();

    // parse payload
    var publishPayload = PublishPayload.fromData(dataPacket);
    publishPayload.parse();
  }

  @override
  void generate() {
    var publishVariableHeader = PublishVariableHeader.create();
    publishVariableHeader.generate();
    var publishPayload = PublishPayload.create();
    publishPayload.generate();

    // create fixed header
    var fixedHeader = FixedHeader.create();
    fixedHeader.setTypeAndFlag('typePub');
    fixedHeader.setRemainingLength(
        publishVariableHeader.getLength() + publishPayload.getLength());
    fixedHeader.generate();

    // write fixed header
    writeDataPacket(fixedHeader.dataPacket);

    // write variable header
    writeDataPacket(publishVariableHeader.dataPacket);
    // write payload
    writeDataPacket(publishPayload.dataPacket);
  }
}

// create PublishVariableHeader class
class PublishVariableHeader extends VariableHeader {
  String topicName = 'test-jinliang';
  int packetIdentifier = Timeline.now;

  PublishVariableHeader.create() : super.create();
  PublishVariableHeader.fromData(DataPacket dataPacket)
      : super.fromData(dataPacket);

  @override
  void parse() {
    // parse topic name
    topicName = readString();
    print('topic name: $topicName');

    // parse packet identifier
    packetIdentifier = readShort();
    print('packet identifier: $packetIdentifier');
  }

  @override
  void generate() {
    // generate topic name
    writeString(topicName);

    // generate packet identifier
    writeShort(packetIdentifier);
  }
}

// create PublishPayload class
class PublishPayload extends Payload {
  String payload = '';

  PublishPayload.create() : super.create();
  PublishPayload.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse payload
    // read all rest data user readRest
    payload = String.fromCharCodes(readRest());

    print('payload: $payload');
  }

  @override
  void generate() {
    // generate payload
    writeString(payload);
  }
}

// create SubscribeMessage class
class SubscribeMessage extends MqttMessage {
  SubscribeMessage.create() : super.create();
  SubscribeMessage.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse fixed header
    var fixedHeader = FixedHeader.fromData(dataPacket);
    fixedHeader.parse();

    // parse variable header
    var subscribeVariableHeader = SubscribeVariableHeader.fromData(dataPacket);
    subscribeVariableHeader.parse();

    // parse payload
    var subscribePayload = SubscribePayload.fromData(dataPacket);
    subscribePayload.parse();
  }

  @override
  void generate() {
    var subscribeVariableHeader = SubscribeVariableHeader.create();
    subscribeVariableHeader.generate();
    var subscribePayload = SubscribePayload.create();
    subscribePayload.generate();

    // create fixed header
    var fixedHeader = FixedHeader.create();
    fixedHeader.setTypeAndFlag('typeSub');
    fixedHeader.setRemainingLength(
        subscribeVariableHeader.getLength() + subscribePayload.getLength());
    fixedHeader.generate();

    // write fixed header
    writeDataPacket(fixedHeader.dataPacket);

    // write variable header
    writeDataPacket(subscribeVariableHeader.dataPacket);
    // write payload
    writeDataPacket(subscribePayload.dataPacket);
  }
}

// create SubscribeVariableHeader class
class SubscribeVariableHeader extends VariableHeader {
  // packet identifier
  int packetIdentifier = Timeline.now;

  SubscribeVariableHeader.create() : super.create();
  SubscribeVariableHeader.fromData(DataPacket dataPacket)
      : super.fromData(dataPacket);

  @override
  void parse() {
    // parse packet identifier
    packetIdentifier = readShort();
  }

  @override
  void generate() {
    // generate packet identifier
    writeShort(packetIdentifier);
  }
}

// create SubscribePayload class
class SubscribePayload extends Payload {
  // topic filter
  String topicFilter = 'test-jinliang';
  // requested QoS
  int requestedQoS = 0;

  SubscribePayload.create() : super.create();
  SubscribePayload.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse topic filter
    topicFilter = readString();
    // parse requested QoS
    requestedQoS = readByte();
  }

  @override
  void generate() {
    // generate topic filter
    writeString(topicFilter);
    // generate requested QoS
    writeByte(requestedQoS & 00000011);
  }
}

// create SubAckMessage class
class SubAckMessage extends MqttMessage {
  SubAckMessage.create() : super.create();
  SubAckMessage.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse fixed header
    var fixedHeader = FixedHeader.fromData(dataPacket);
    fixedHeader.parse();

    // parse variable header
    var subAckVariableHeader = SubAckVariableHeader.fromData(dataPacket);
    subAckVariableHeader.parse();

    // parse payload
    var subAckPayload = SubAckPayload.fromData(dataPacket);
    subAckPayload.parse();
  }

  @override
  void generate() {
    var subAckVariableHeader = SubAckVariableHeader.create();
    subAckVariableHeader.generate();
    var subAckPayload = SubAckPayload.create();
    subAckPayload.generate();

    // create fixed header
    var fixedHeader = FixedHeader.create();
    fixedHeader.setTypeAndFlag('typeSubAck');
    fixedHeader.setRemainingLength(
        subAckVariableHeader.getLength() + subAckPayload.getLength());
    fixedHeader.generate();

    // write fixed header
    writeDataPacket(fixedHeader.dataPacket);

    // write variable header
    writeDataPacket(subAckVariableHeader.dataPacket);
    // write payload
    writeDataPacket(subAckPayload.dataPacket);
  }
}

// create SubAckVariableHeader class
class SubAckVariableHeader extends VariableHeader {
  // packet identifier
  int packetIdentifier = 0;

  SubAckVariableHeader.create() : super.create();
  SubAckVariableHeader.fromData(DataPacket dataPacket)
      : super.fromData(dataPacket);

  @override
  void parse() {
    // parse packet identifier
    packetIdentifier = readShort();
  }

  @override
  void generate() {
    // generate packet identifier
    writeShort(packetIdentifier);
  }
}

// create SubAckPayload class
class SubAckPayload extends Payload {
  // granted QoS
  int grantedQoS = 0;

  SubAckPayload.create() : super.create();
  SubAckPayload.fromData(DataPacket dataPacket) : super.fromData(dataPacket);

  @override
  void parse() {
    // parse granted QoS
    grantedQoS = readByte();
  }

  @override
  void generate() {
    // generate granted QoS
    writeByte(grantedQoS & 00000011);
  }
}

// debug flag
bool debugEnabled = true;

void debug(Uint8List data) {
  if (!debugEnabled) {
    return;
  }
  for (var byte in data) {
    var str = byte.toRadixString(2);
    while (str.length < 8) {
      str = '0$str';
    }
    print(str);
  }
}

void main() {
  // create a connect message
  var connectMessage = ConnectMessage.create();
  connectMessage.generate();
  // connectMessage.parse();

  // create a subscribe message
  var subscribeMessage = SubscribeMessage.create();
  subscribeMessage.generate();
  // subscribeMessage.parse();

  // host: broker.emqx.io tcp port:1883

  var conn = Connection();
  // 'broker.hivemq.com'
  conn.connect('broker.emqx.io', 1883).setCallback((data) {
    parseMessage(data).parse();
  });

  // connect to broker
  conn.sendMessage(connectMessage.toBuffer());
  // subscribe to topic
  conn.sendMessage(subscribeMessage.toBuffer());
}
