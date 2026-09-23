import 'package:uuid/uuid.dart';

import '../../../../core/money/money_minor.dart';
import '../../service_order_entity.dart';

enum ServiceOrderProjectionAudience { staff, customer }

final class ServiceOrderProjectionItemDto {
  const ServiceOrderProjectionItemDto({
    this.id,
    this.serviceOrderId,
    this.partId,
    required this.description,
    required this.quantity,
    required this.unitPriceMinor,
    required this.totalPriceMinor,
    this.createdAt,
  });

  final String? id;
  final String? serviceOrderId;
  final String? partId;
  final String description;
  final int quantity;
  final int unitPriceMinor;
  final int totalPriceMinor;
  final String? createdAt;

  factory ServiceOrderProjectionItemDto.fromWire(
    Map<String, dynamic> wire, {
    required ServiceOrderProjectionAudience audience,
    required String expectedServiceOrderId,
  }) {
    final staff = audience == ServiceOrderProjectionAudience.staff;
    _expectExactKeys(
      wire,
      staff
          ? const {
              'id',
              'serviceOrderId',
              'partId',
              'description',
              'quantity',
              'unitPriceMinor',
              'totalPriceMinor',
              'createdAt',
            }
          : const {
              'description',
              'quantity',
              'unitPriceMinor',
              'totalPriceMinor',
            },
      'ServiceOrderProjectionItem',
    );

    final id = staff ? _requiredUuid(wire, 'id') : null;
    final serviceOrderId = staff ? _requiredUuid(wire, 'serviceOrderId') : null;
    if (serviceOrderId != null && serviceOrderId != expectedServiceOrderId) {
      throw const FormatException('Projection item parent does not match.');
    }
    final partId = staff ? _nullableUuid(wire, 'partId') : null;
    final quantity = _requiredInt(wire, 'quantity', minimum: 1);
    final unitPrice = MoneyMinor.serviceOrderFromJson(wire['unitPriceMinor']);
    final totalPrice = MoneyMinor.serviceOrderFromJson(wire['totalPriceMinor']);
    if (unitPrice.multiplyByQuantity(
          quantity,
          maximum: MoneyMinor.serviceOrderMaximum,
        ) !=
        totalPrice) {
      throw const FormatException('Projection item total is inconsistent.');
    }

    return ServiceOrderProjectionItemDto(
      id: id,
      serviceOrderId: serviceOrderId,
      partId: partId,
      description: _requiredString(wire, 'description'),
      quantity: quantity,
      unitPriceMinor: unitPrice.minorUnits,
      totalPriceMinor: totalPrice.minorUnits,
      createdAt: staff ? _requiredTimestamp(wire, 'createdAt') : null,
    );
  }

  Map<String, Object?> toWire(ServiceOrderProjectionAudience audience) => {
        if (audience == ServiceOrderProjectionAudience.staff) 'id': id,
        if (audience == ServiceOrderProjectionAudience.staff)
          'serviceOrderId': serviceOrderId,
        if (audience == ServiceOrderProjectionAudience.staff) 'partId': partId,
        'description': description,
        'quantity': quantity,
        'unitPriceMinor': unitPriceMinor,
        'totalPriceMinor': totalPriceMinor,
        if (audience == ServiceOrderProjectionAudience.staff)
          'createdAt': createdAt,
      };
}

/// Typed Projection v2 DTO. It retains projection metadata without adding it
/// to [ServiceOrderEntity]. CUSTOMER parsing uses an exact allowlist so a rich
/// administrative representation can never be promoted to local authority.
final class ServiceOrderProjectionDto {
  const ServiceOrderProjectionDto({
    required this.audience,
    required this.projectionRevision,
    required this.id,
    required this.friendlyId,
    this.organizationId,
    this.customerId,
    required this.equipmentId,
    this.technicianId,
    required this.status,
    required this.problemDescription,
    this.diagnosis,
    this.solution,
    required this.totalAmountMinor,
    this.currentQuoteRevisionId,
    this.lastApprovedQuoteRevisionId,
    this.materializedQuoteRevisionId,
    this.commercialScopeSource,
    required this.createdAt,
    required this.updatedAt,
    required this.items,
  });

  final ServiceOrderProjectionAudience audience;
  final String projectionRevision;
  final String id;
  final int friendlyId;
  final String? organizationId;
  final String? customerId;
  final String equipmentId;
  final String? technicianId;
  final ServiceOrderStatusEnum status;
  final String problemDescription;
  final String? diagnosis;
  final String? solution;
  final int totalAmountMinor;
  final String? currentQuoteRevisionId;
  final String? lastApprovedQuoteRevisionId;
  final String? materializedQuoteRevisionId;
  final String? commercialScopeSource;
  final String createdAt;
  final String updatedAt;
  final List<ServiceOrderProjectionItemDto> items;

  factory ServiceOrderProjectionDto.fromWire(
    Map<String, dynamic> wire, {
    required ServiceOrderProjectionAudience audience,
    String? expectedServiceOrderId,
  }) {
    final staff = audience == ServiceOrderProjectionAudience.staff;
    _expectExactKeys(
      wire,
      staff ? _staffProjectionKeys : _customerProjectionKeys,
      'ServiceOrderProjection',
    );
    if (wire['contractVersion'] != 2) {
      throw const FormatException('Projection contractVersion must be 2.');
    }
    final revision = _requiredString(wire, 'projectionRevision');
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(revision)) {
      throw const FormatException('Projection revision is not canonical.');
    }
    final id = _requiredUuid(wire, 'id');
    if (expectedServiceOrderId != null && id != expectedServiceOrderId) {
      throw const FormatException(
          'Projection service-order id does not match.');
    }
    final rawItems = wire['items'];
    if (rawItems is! List) {
      throw const FormatException('Projection items must be a list.');
    }
    final items = rawItems
        .map(
          (item) => ServiceOrderProjectionItemDto.fromWire(
            _requiredMap(item, 'Projection item'),
            audience: audience,
            expectedServiceOrderId: id,
          ),
        )
        .toList(growable: false);
    final total = MoneyMinor.serviceOrderFromJson(wire['totalAmountMinor']);
    final aggregate = MoneyMinor.sum(
      items.map(
        (item) => MoneyMinor.serviceOrder(item.totalPriceMinor),
      ),
      maximum: MoneyMinor.serviceOrderMaximum,
    );
    if (aggregate != total) {
      throw const FormatException(
          'Projection aggregate total is inconsistent.');
    }
    final status = ServiceOrderStatusExtension.fromDbString(wire['status']);
    final source =
        staff ? _requiredString(wire, 'commercialScopeSource') : null;
    if (source != null &&
        !const {
          'UNPUBLISHED',
          'CURRENT_QUOTE',
          'LAST_APPROVED_QUOTE',
        }.contains(source)) {
      throw const FormatException('Projection commercial source is invalid.');
    }

    return ServiceOrderProjectionDto(
      audience: audience,
      projectionRevision: revision,
      id: id,
      friendlyId: _requiredInt(wire, 'friendlyId', minimum: 1),
      organizationId: staff ? _requiredUuid(wire, 'organizationId') : null,
      customerId: staff ? _requiredUuid(wire, 'customerId') : null,
      equipmentId: _requiredUuid(wire, 'equipmentId'),
      technicianId: staff ? _nullableUuid(wire, 'technicianId') : null,
      status: status,
      problemDescription: _requiredString(wire, 'problemDescription'),
      diagnosis: _nullableString(wire, 'diagnosis'),
      solution: _nullableString(wire, 'solution'),
      totalAmountMinor: total.minorUnits,
      currentQuoteRevisionId:
          staff ? _nullableUuid(wire, 'currentQuoteRevisionId') : null,
      lastApprovedQuoteRevisionId:
          staff ? _nullableUuid(wire, 'lastApprovedQuoteRevisionId') : null,
      materializedQuoteRevisionId:
          staff ? _nullableUuid(wire, 'materializedQuoteRevisionId') : null,
      commercialScopeSource: source,
      createdAt: _requiredTimestamp(wire, 'createdAt'),
      updatedAt: _requiredTimestamp(wire, 'updatedAt'),
      items: List.unmodifiable(items),
    );
  }

  Map<String, Object?> toWire() => {
        'contractVersion': 2,
        'projectionRevision': projectionRevision,
        'id': id,
        'friendlyId': friendlyId,
        if (audience == ServiceOrderProjectionAudience.staff)
          'organizationId': organizationId,
        if (audience == ServiceOrderProjectionAudience.staff)
          'customerId': customerId,
        'equipmentId': equipmentId,
        if (audience == ServiceOrderProjectionAudience.staff)
          'technicianId': technicianId,
        'status': status.toDbString(),
        'problemDescription': problemDescription,
        'solution': solution,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'diagnosis': diagnosis,
        'totalAmountMinor': totalAmountMinor,
        if (audience == ServiceOrderProjectionAudience.staff)
          'currentQuoteRevisionId': currentQuoteRevisionId,
        if (audience == ServiceOrderProjectionAudience.staff)
          'lastApprovedQuoteRevisionId': lastApprovedQuoteRevisionId,
        if (audience == ServiceOrderProjectionAudience.staff)
          'materializedQuoteRevisionId': materializedQuoteRevisionId,
        if (audience == ServiceOrderProjectionAudience.staff)
          'commercialScopeSource': commercialScopeSource,
        'items': items.map((item) => item.toWire(audience)).toList(),
      };
}

/// STAFF-only DTO for the current administrative GET list/detail contracts.
/// It is deliberately not convertible to [ServiceOrderEntity] or a SQLite row.
final class ServiceOrderAdministrativeDto {
  const ServiceOrderAdministrativeDto({
    required this.id,
    required this.friendlyId,
    required this.organizationId,
    required this.customerId,
    required this.equipmentId,
    this.technicianId,
    required this.status,
    required this.problemDescription,
    required this.createdAt,
    required this.updatedAt,
    required this.organization,
    required this.customer,
    required this.equipment,
    this.technician,
  });

  final String id;
  final int friendlyId;
  final String organizationId;
  final String customerId;
  final String equipmentId;
  final String? technicianId;
  final ServiceOrderStatusEnum status;
  final String problemDescription;
  final String createdAt;
  final String updatedAt;
  final Map<String, dynamic> organization;
  final Map<String, dynamic> customer;
  final Map<String, dynamic> equipment;
  final Map<String, dynamic>? technician;

  factory ServiceOrderAdministrativeDto.fromWire(Map<String, dynamic> wire) {
    _expectExactKeys(wire, _administrativeKeys, 'Administrative service order');
    final id = _requiredUuid(wire, 'id');
    final organizationId = _requiredUuid(wire, 'organizationId');
    final customerId = _requiredUuid(wire, 'customerId');
    final equipmentId = _requiredUuid(wire, 'equipmentId');
    final technicianId = _nullableUuid(wire, 'technicianId');
    final organization = _requiredMap(
      wire['organization'],
      'Administrative organization',
    );
    final customer = _requiredMap(
      wire['customer'],
      'Administrative customer',
    );
    final equipment = _requiredMap(
      wire['equipment'],
      'Administrative equipment',
    );
    final technician = wire['technician'];
    if (technician != null && technician is! Map<String, dynamic>) {
      throw const FormatException(
          'Administrative technician must be an object.');
    }
    _expectRelation(
      organization,
      expectedKeys: const {'id', 'name'},
      expectedId: organizationId,
      label: 'organization',
    );
    _expectRelation(
      customer,
      expectedKeys: const {
        'id',
        'name',
        'document',
        'email',
        'phone',
        'address',
        'createdAt',
        'updatedAt',
      },
      expectedId: customerId,
      label: 'customer',
    );
    _expectRelation(
      equipment,
      expectedKeys: const {
        'id',
        'customerId',
        'organizationId',
        'ownerType',
        'organizationPurpose',
        'brand',
        'model',
        'serialNumber',
        'type',
        'notes',
        'createdAt',
        'updatedAt',
      },
      expectedId: equipmentId,
      label: 'equipment',
      requireName: false,
    );
    if (technicianId == null && technician != null ||
        technicianId != null && technician == null) {
      throw const FormatException(
          'Administrative technician identity diverged.');
    }
    if (technician is Map<String, dynamic>) {
      _expectRelation(
        technician,
        expectedKeys: const {'id', 'name'},
        expectedId: technicianId!,
        label: 'technician',
      );
    }
    final financeCoreVersion = wire['financeCoreVersion'];
    if (financeCoreVersion != null && financeCoreVersion is! int) {
      throw const FormatException(
          'financeCoreVersion must be an integer or null.');
    }
    _nullableUuid(wire, 'currentQuoteRevisionId');
    _nullableUuid(wire, 'lastApprovedQuoteRevisionId');
    _nullableString(wire, 'diagnosis');
    _nullableString(wire, 'solution');
    final totalAmount = wire['totalAmount'];
    if (totalAmount is! String && totalAmount is! num) {
      throw const FormatException('totalAmount must be a decimal value.');
    }
    return ServiceOrderAdministrativeDto(
      id: id,
      friendlyId: _requiredInt(wire, 'friendlyId', minimum: 1),
      organizationId: organizationId,
      customerId: customerId,
      equipmentId: equipmentId,
      technicianId: technicianId,
      status: ServiceOrderStatusExtension.fromDbString(wire['status']),
      problemDescription: _requiredString(wire, 'problemDescription'),
      createdAt: _requiredTimestamp(wire, 'createdAt'),
      updatedAt: _requiredTimestamp(wire, 'updatedAt'),
      organization: Map.unmodifiable(organization),
      customer: Map.unmodifiable(customer),
      equipment: Map.unmodifiable(equipment),
      technician: technician == null
          ? null
          : Map.unmodifiable(Map<String, dynamic>.from(technician)),
    );
  }

  static List<ServiceOrderAdministrativeDto> listFromEnvelope(
    Map<String, dynamic> envelope,
  ) {
    _expectExactKeys(envelope, const {'orders'}, 'Service-order list envelope');
    final orders = envelope['orders'];
    if (orders is! List) {
      throw const FormatException('Service-order list is missing.');
    }
    return List.unmodifiable(
      orders.map(
        (order) => ServiceOrderAdministrativeDto.fromWire(
          _requiredMap(order, 'Administrative service order'),
        ),
      ),
    );
  }

  static ServiceOrderAdministrativeDto detailFromEnvelope(
    Map<String, dynamic> envelope,
  ) {
    _expectExactKeys(
        envelope, const {'order'}, 'Service-order detail envelope');
    return ServiceOrderAdministrativeDto.fromWire(
      _requiredMap(envelope['order'], 'Administrative service order'),
    );
  }
}

void _expectRelation(
  Map<String, dynamic> wire, {
  required Set<String> expectedKeys,
  required String expectedId,
  required String label,
  bool requireName = true,
}) {
  _expectExactKeys(wire, expectedKeys, 'Administrative $label');
  if (_requiredUuid(wire, 'id') != expectedId) {
    throw FormatException('Administrative $label identity diverged.');
  }
  if (requireName) _requiredString(wire, 'name');
}

const _customerProjectionKeys = {
  'contractVersion',
  'projectionRevision',
  'id',
  'friendlyId',
  'equipmentId',
  'status',
  'problemDescription',
  'solution',
  'createdAt',
  'updatedAt',
  'diagnosis',
  'totalAmountMinor',
  'items',
};

const _staffProjectionKeys = {
  ..._customerProjectionKeys,
  'organizationId',
  'customerId',
  'technicianId',
  'currentQuoteRevisionId',
  'lastApprovedQuoteRevisionId',
  'materializedQuoteRevisionId',
  'commercialScopeSource',
};

const _administrativeKeys = {
  'id',
  'friendlyId',
  'organizationId',
  'customerId',
  'equipmentId',
  'technicianId',
  'financeCoreVersion',
  'currentQuoteRevisionId',
  'lastApprovedQuoteRevisionId',
  'status',
  'problemDescription',
  'diagnosis',
  'solution',
  'totalAmount',
  'createdAt',
  'updatedAt',
  'organization',
  'customer',
  'equipment',
  'technician',
};

void _expectExactKeys(
  Map<String, dynamic> wire,
  Set<String> expected,
  String label,
) {
  final actual = wire.keys.toSet();
  if (actual.difference(expected).isNotEmpty ||
      expected.difference(actual).isNotEmpty) {
    throw FormatException('$label has unexpected or missing keys.');
  }
}

Map<String, dynamic> _requiredMap(Object? value, String label) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$label must be an object.');
  }
  return value;
}

String _requiredString(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string.');
  }
  return value;
}

String? _nullableString(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  if (value != null && value is! String) {
    throw FormatException('$key must be a string or null.');
  }
  return value as String?;
}

int _requiredInt(
  Map<String, dynamic> wire,
  String key, {
  required int minimum,
}) {
  final value = wire[key];
  if (value is! int || value < minimum) {
    throw FormatException('$key must be an integer >= $minimum.');
  }
  return value;
}

String _requiredUuid(Map<String, dynamic> wire, String key) {
  final value = _requiredString(wire, key);
  if (!Uuid.isValidUUID(fromString: value)) {
    throw FormatException('$key must be a UUID.');
  }
  return value;
}

String? _nullableUuid(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  if (value == null) return null;
  if (value is! String || !Uuid.isValidUUID(fromString: value)) {
    throw FormatException('$key must be a UUID or null.');
  }
  return value;
}

String _requiredTimestamp(Map<String, dynamic> wire, String key) {
  final value = _requiredString(wire, key);
  if (DateTime.tryParse(value) == null) {
    throw FormatException('$key must be an ISO-8601 timestamp.');
  }
  return value;
}
