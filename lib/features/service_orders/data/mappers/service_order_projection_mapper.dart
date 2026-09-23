import '../dtos/service_order_read_dto.dart';

abstract final class ServiceOrderProjectionMapper {
  static Map<String, dynamic> toSyncRecord(ServiceOrderProjectionDto dto) => {
        'entityType': 'SERVICE_ORDER',
        'entityId': dto.id,
        'data': Map<String, dynamic>.from(dto.toWire()),
      };
}
