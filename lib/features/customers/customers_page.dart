import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'customers_provider.dart';
import 'customer_entity.dart';

class CustomersPage extends ConsumerWidget {
  const CustomersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customersAsync = ref.watch(customersProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.people_alt, color: Color(0xFF38BDF8)),
            SizedBox(width: 10),
            Text(
              'Clientes',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
            onPressed: () => ref.read(customersProvider.notifier).refresh(),
          ),
        ],
      ),
      body: customersAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
        error: (err, _) => Center(
          child: Text('Erro: $err',
              style: const TextStyle(color: Colors.redAccent)),
        ),
        data: (customers) {
          if (customers.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.person_off, size: 64, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  const Text(
                    'Nenhum cliente cadastrado',
                    style: TextStyle(fontSize: 16, color: Colors.white54),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: customers.length,
            itemBuilder: (context, index) {
              final customer = customers[index];
              return _CustomerCard(customer: customer);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0284C7),
        onPressed: () => _showCreateCustomerDialog(context, ref),
        icon: const Icon(Icons.person_add, color: Colors.white),
        label: const Text(
          'Novo Cliente',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _showCreateCustomerDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final phoneController = TextEditingController();
    final documentController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Novo Cliente',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTextField(nameController, 'Nome *', Icons.person),
              const SizedBox(height: 12),
              _buildTextField(documentController, 'CPF / CNPJ', Icons.badge),
              const SizedBox(height: 12),
              _buildTextField(emailController, 'E-mail', Icons.email,
                  keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 12),
              _buildTextField(phoneController, 'Telefone', Icons.phone,
                  keyboardType: TextInputType.phone),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7)),
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              await ref.read(customersProvider.notifier).createCustomer(
                    name: nameController.text.trim(),
                    document: documentController.text.trim().isEmpty
                        ? null
                        : documentController.text.trim(),
                    email: emailController.text.trim().isEmpty
                        ? null
                        : emailController.text.trim(),
                    phone: phoneController.text.trim().isEmpty
                        ? null
                        : phoneController.text.trim(),
                  );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Salvar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF38BDF8)),
        ),
        filled: true,
        fillColor: const Color(0xFF0F172A),
      ),
    );
  }
}

class _CustomerCard extends ConsumerWidget {
  final CustomerEntity customer;
  const _CustomerCard({required this.customer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initials = customer.name
        .trim()
        .split(' ')
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();

    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF0284C7),
          child: Text(
            initials,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(
          customer.name,
          style:
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (customer.email != null)
              Text(customer.email!,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
            if (customer.phone != null)
              Text(customer.phone!,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
            if (customer.document != null)
              Text('Doc: ${customer.document}',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ],
        ),
        trailing: PopupMenuButton<String>(
          color: const Color(0xFF1E293B),
          icon: const Icon(Icons.more_vert, color: Colors.white54),
          onSelected: (value) {
            if (value == 'delete') {
              ref.read(customersProvider.notifier).deleteCustomer(customer.id);
            }
          },
          itemBuilder: (ctx) => [
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: Colors.redAccent, size: 18),
                  SizedBox(width: 8),
                  Text('Excluir', style: TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
