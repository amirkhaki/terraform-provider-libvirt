# Visual Explanation: Domain Update Flow

## Before the Fix (WRONG ❌)

```
User updates vcpu: 1 → 2

Terraform detects change
         ↓
    Update() method
         ↓
  Shutdown domain
         ↓
  DomainUndefine(domain)  ← DESTROYS THE VM!
         ↓
  DomainDefineXML(new_xml)  ← Creates a "new" domain
         ↓
    Start domain
         ↓
Result: NEW domain with NEW identity
        (Terraform sees this as a replacement)
```

**Problems:**
- Domain UUID changes (or would change without UUID preservation)
- All runtime state lost
- Appears as "destroy + recreate" in Terraform plan
- Non-persistent data lost

## After the Fix (CORRECT ✅)

```
User updates vcpu: 1 → 2

Terraform detects change
         ↓
    Update() method
         ↓
  Preserve UUID from state
  (planData.SanitizedModel.UUID = state.UUID)
         ↓
  Shutdown domain
         ↓
  DomainDefineXML(xml_with_same_uuid)  ← libvirt REPLACES definition
         ↓
    Start domain
         ↓
Result: SAME domain with updated config
        (Terraform sees this as an update)
```

**Benefits:**
- ✅ Same domain UUID (Terraform tracks it as the same resource)
- ✅ Only configuration updated
- ✅ Appears as "update in-place" in Terraform plan
- ✅ Faster (no destroy/recreate cycle)
- ✅ Safer (no risk of data loss from improper cleanup)

## libvirt API Behavior

```c
// libvirt API documentation (paraphrased):

virDomainDefineXML(conn, xml_with_uuid_X) {
    if (domain_with_uuid_X_exists) {
        // Update the existing domain's definition
        replace_definition(uuid_X, new_xml);
        return domain_handle_X;
    } else {
        // Create a new domain with this UUID
        create_new_domain(new_xml);
        return new_domain_handle;
    }
}
```

**Key insight:** libvirt's `DomainDefineXML()` is smart enough to handle both create AND update based on UUID presence. The provider doesn't need to manually undefine first.

## Code Comparison

### Before
```go
// Undefine the domain (WRONG - destroys it)
if err := r.client.Libvirt().DomainUndefine(existingDomain); err != nil {
    return err
}

// Define "new" domain (actually recreating)
newDomain, err := r.client.Libvirt().DomainDefineXML(xmlString)
```

### After
```go
// Define the domain with the updated XML.
// Since the UUID is preserved, this replaces the existing domain definition.
// No need to undefine first - DomainDefineXML with the same UUID updates in-place.
newDomain, err := r.client.Libvirt().DomainDefineXML(xmlString)
```

**Lines removed:** 7  
**Lines added:** 3 (comments)  
**Net change:** Simpler, clearer, and correct!

## Terraform Plan Output

### Before the Fix
```
Terraform will perform the following actions:

  # libvirt_domain.test must be replaced
-/+ resource "libvirt_domain" "test" {
      ~ memory = 512 -> 1024  # forces replacement
      ~ vcpu   = 1   -> 2     # forces replacement
        # ...
    }

Plan: 1 to add, 0 to change, 1 to destroy.
```

### After the Fix
```
Terraform will perform the following actions:

  # libvirt_domain.test will be updated in-place
  ~ resource "libvirt_domain" "test" {
      ~ memory = 512 -> 1024
      ~ vcpu   = 1   -> 2
        # ...
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

Much better! The user can clearly see the domain is being updated, not destroyed.
