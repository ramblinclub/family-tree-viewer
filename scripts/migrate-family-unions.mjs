#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || !value) {
      throw new Error(`Expected --name value, received ${key ?? '<end>'}`);
    }
    result[key.slice(2)] = value;
  }
  for (const required of ['store', 'corrections', 'backup']) {
    if (!result[required]) throw new Error(`Missing --${required}`);
  }
  return result;
}

function readJson(filename) {
  return JSON.parse(fs.readFileSync(filename, 'utf8'));
}

function writeJson(filename, value) {
  fs.writeFileSync(filename, `${JSON.stringify(value, null, 2)}\n`);
}

function splitGedcomRecords(text) {
  const records = [];
  let current = [];
  for (const line of text.split(/\r?\n/)) {
    if (line.startsWith('0 ') && current.length) {
      records.push(current);
      current = [];
    }
    if (line || current.length) current.push(line);
  }
  if (current.length) records.push(current);
  return records;
}

function parseSourceFamilies(text) {
  const families = [];
  const sexByID = new Map();
  let sourceOrder = 0;
  for (const record of splitGedcomRecords(text)) {
    const individual = record[0]?.match(/^0 @([^@]+)@ INDI$/);
    if (individual) {
      const sex = record.find((line) => /^1 SEX [MFU]$/.test(line))?.slice(6);
      if (sex) sexByID.set(individual[1], sex);
      continue;
    }
    const family = record[0]?.match(/^0 @([^@]+)@ FAM$/);
    if (!family) continue;
    const partnerIDs = record
      .map((line) => line.match(/^1 (?:HUSB|WIFE) @([^@]+)@$/)?.[1])
      .filter(Boolean)
      .sort();
    const childIDs = record
      .map((line) => line.match(/^1 CHIL @([^@]+)@$/)?.[1])
      .filter(Boolean)
      .sort();
    const marriageIndex = record.findIndex((line) => line === '1 MARR');
    const marriageDate = marriageIndex >= 0
      ? record.slice(marriageIndex + 1).find((line) => /^2 DATE /.test(line))?.slice(7)
      : undefined;
    const divorceIndex = record.findIndex((line) => line === '1 DIV');
    const statusDate = divorceIndex >= 0
      ? record.slice(divorceIndex + 1).find((line) => /^2 DATE /.test(line))?.slice(7)
      : undefined;
    const relationshipType = record.find((line) => /^1 _SREL /.test(line))?.slice(8);
    families.push({
      id: family[1],
      partnerIDs,
      childIDs,
      marriageDate,
      statusDate,
      relationshipStatus: divorceIndex >= 0
        ? 'divorced'
        : marriageIndex >= 0
          ? 'married'
          : relationshipType,
      sourceOrder: sourceOrder++,
    });
  }
  return {families, sexByID};
}

function pairKey(ids) {
  return [...new Set(ids)].sort().join('|');
}

function yearFrom(value) {
  const match = value?.match(/(?:^|\D)(\d{4})(?:\D|$)/);
  return match ? Number(match[1]) : Number.MAX_SAFE_INTEGER;
}

function copyBackup(store, backup) {
  if (fs.existsSync(backup)) throw new Error(`Backup already exists: ${backup}`);
  fs.mkdirSync(backup, {recursive: true});
  for (const name of ['manifest.json', 'family.ged', 'family-unions.json']) {
    const source = path.join(store, name);
    if (fs.existsSync(source)) fs.copyFileSync(source, path.join(backup, name));
  }
  fs.cpSync(path.join(store, 'people'), path.join(backup, 'people'), {recursive: true});
  const corrections = path.join(store, 'PrivateData', 'relationship-corrections.private.json');
  if (fs.existsSync(corrections)) {
    fs.mkdirSync(path.join(backup, 'PrivateData'), {recursive: true});
    fs.copyFileSync(corrections, path.join(backup, 'PrivateData', path.basename(corrections)));
  }
}

function applyParentOverrides(peopleByID, overrides) {
  for (const [childID, parentIDs] of Object.entries(overrides ?? {})) {
    const child = peopleByID.get(childID);
    if (!child) throw new Error(`Unknown child in parent override: ${childID}`);
    const normalizedParents = [...new Set(parentIDs)];
    if (normalizedParents.length > 2) throw new Error(`More than two canonical parents for ${childID}`);
    for (const parentID of normalizedParents) {
      if (!peopleByID.has(parentID)) throw new Error(`Unknown parent ${parentID} for ${childID}`);
    }
    for (const person of peopleByID.values()) {
      const children = new Set(person.immediateFamily.children ?? []);
      if (normalizedParents.includes(person.id)) children.add(childID);
      else children.delete(childID);
      person.immediateFamily.children = [...children].sort();
    }
    child.immediateFamily.parents = normalizedParents.sort();
  }
}

function deriveUnions(people, sourceFamilies, corrections) {
  const validIDs = new Set(people.map((person) => person.id));
  const unionsByPair = new Map();
  const ensureUnion = (partnerIDs) => {
    const normalized = [...new Set(partnerIDs.filter((id) => validIDs.has(id)))].sort();
    if (!normalized.length || normalized.length > 2) return undefined;
    const key = pairKey(normalized);
    if (!unionsByPair.has(key)) {
      unionsByPair.set(key, {
        partnerIDs: normalized,
        childIDs: new Set(),
        relationshipStatus: null,
        statusDate: null,
        statusDateIsApproximate: null,
      });
    }
    return unionsByPair.get(key);
  };

  for (const child of people) {
    const parents = [...new Set(child.immediateFamily.parents.filter((id) => validIDs.has(id)))].sort();
    if (parents.length > 2) throw new Error(`Unresolved three-parent record: ${child.id}`);
    if (parents.length) {
      const union = ensureUnion(parents);
      union?.childIDs.add(child.id);
      if (child.immediateFamily.parentsUnionStatus && !union.relationshipStatus) {
        union.relationshipStatus = child.immediateFamily.parentsUnionStatus;
        union.statusDate = child.immediateFamily.parentsUnionDate ?? null;
        union.statusDateIsApproximate = child.immediateFamily.parentsUnionDateIsApproximate ?? null;
      }
    }
  }
  for (const person of people) {
    for (const partnerID of person.immediateFamily.partners) {
      if (validIDs.has(partnerID)) ensureUnion([person.id, partnerID]);
    }
  }

  const sourceByPair = new Map();
  for (const family of sourceFamilies) {
    const key = pairKey(family.partnerIDs);
    if (!key) continue;
    const candidates = sourceByPair.get(key) ?? [];
    candidates.push(family);
    sourceByPair.set(key, candidates);
  }

  const confirmedPairs = new Set((corrections.confirmedUnions ?? []).map((union) => pairKey(union.partnerIDs)));
  const unionOverrides = new Map((corrections.unionOverrides ?? []).map((union) => [pairKey(union.partnerIDs), union]));
  const usedIDs = new Set();
  const unions = [...unionsByPair.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([key, value], index) => {
    const children = [...value.childIDs].sort();
    const candidates = sourceByPair.get(key) ?? [];
    const source = candidates
      .map((candidate) => ({
        candidate,
        overlap: candidate.childIDs.filter((id) => children.includes(id)).length,
      }))
      .sort((left, right) => right.overlap - left.overlap || left.candidate.sourceOrder - right.candidate.sourceOrder)[0]?.candidate;
    const override = unionOverrides.get(key) ?? {};
    let id = override.id ?? source?.id ?? `family-${index + 1}`;
    while (usedIDs.has(id)) id = `${id}-${index + 1}`;
    usedIDs.add(id);
    return {
      id,
      partnerIDs: value.partnerIDs,
      childIDs: override.childIDs ? [...new Set(override.childIDs)].sort() : children,
      relationshipStatus: override.relationshipStatus ?? source?.relationshipStatus ?? value.relationshipStatus,
      marriageDate: override.marriageDate ?? source?.marriageDate ?? null,
      statusDate: override.statusDate ?? source?.statusDate ?? value.statusDate,
      marriageDateIsApproximate: override.marriageDateIsApproximate ?? value.statusDateIsApproximate,
      partnerSequence: override.partnerSequence ?? null,
      sourceFamilyID: override.sourceFamilyID ?? source?.id ?? null,
      provenance: override.provenance ?? (confirmedPairs.has(key) ? 'owner-confirmed' : 'normalized-migration'),
      sourceOrder: source?.sourceOrder ?? Number.MAX_SAFE_INTEGER,
    };
  });

  for (const person of people) {
    const relationships = unions
      .filter((union) => union.partnerIDs.includes(person.id) && union.partnerIDs.length > 1)
      .sort((left, right) => {
        const yearDifference = yearFrom(left.marriageDate) - yearFrom(right.marriageDate);
        return yearDifference || left.sourceOrder - right.sourceOrder || left.id.localeCompare(right.id);
      });
    const hasOrderingEvidence = relationships.some((union) =>
      union.partnerSequence?.[person.id] != null ||
      yearFrom(union.marriageDate) !== Number.MAX_SAFE_INTEGER ||
      union.sourceOrder !== Number.MAX_SAFE_INTEGER
    );
    if (!hasOrderingEvidence) continue;
    let nextSequence = 1;
    relationships.forEach((union) => {
      union.partnerSequence ??= {};
      if (union.partnerSequence[person.id] == null) {
        while (relationships.some((candidate) => candidate.partnerSequence?.[person.id] === nextSequence)) nextSequence += 1;
        union.partnerSequence[person.id] = nextSequence;
      }
      nextSequence += 1;
    });
  }
  return unions.map(({sourceOrder, ...union}) => union);
}

function rebuildCompatibilityIndex(people, unions) {
  const validIDs = new Set(people.map((person) => person.id));
  const parents = new Map(people.map((person) => [person.id, new Set()]));
  const children = new Map(people.map((person) => [person.id, new Set()]));
  const partners = new Map(people.map((person) => [person.id, new Set()]));

  for (const union of unions) {
    for (const partnerID of union.partnerIDs) {
      for (const otherID of union.partnerIDs) if (otherID !== partnerID) partners.get(partnerID)?.add(otherID);
      for (const childID of union.childIDs) children.get(partnerID)?.add(childID);
    }
    for (const childID of union.childIDs) {
      for (const parentID of union.partnerIDs) parents.get(childID)?.add(parentID);
    }
  }

  for (const person of people) {
    person.immediateFamily.parents = [...parents.get(person.id)].sort();
    person.immediateFamily.children = [...children.get(person.id)].sort();
    person.immediateFamily.partners = [...partners.get(person.id)].sort();
  }

  for (const person of people) {
    const siblingIDs = new Set((person.immediateFamily.siblings ?? []).filter((id) => validIDs.has(id) && id !== person.id));
    const personParents = parents.get(person.id);
    if (personParents?.size) {
      for (const candidate of people) {
        if (candidate.id === person.id) continue;
        const candidateParents = parents.get(candidate.id);
        if (candidateParents && [...personParents].some((id) => candidateParents.has(id))) siblingIDs.add(candidate.id);
      }
    }
    person.immediateFamily.siblings = [...siblingIDs].sort();
  }
  for (const person of people) {
    for (const siblingID of person.immediateFamily.siblings) {
      const sibling = people.find((candidate) => candidate.id === siblingID);
      if (sibling && !sibling.immediateFamily.siblings.includes(person.id)) {
        sibling.immediateFamily.siblings.push(person.id);
        sibling.immediateFamily.siblings.sort();
      }
    }
  }

  for (const person of people) {
    const parentKey = pairKey(person.immediateFamily.parents);
    const union = unions.find((candidate) => pairKey(candidate.partnerIDs) === parentKey && candidate.childIDs.includes(person.id));
    person.immediateFamily.parentsUnionStatus = union?.relationshipStatus === 'divorced' ? 'divorced' : null;
    person.immediateFamily.parentsUnionDate = union?.statusDate ?? null;
    person.immediateFamily.parentsUnionDateIsApproximate = union?.marriageDateIsApproximate ?? null;
  }
}

function gedcomRoles(partnerIDs, sexByID) {
  let husband;
  let wife;
  for (const id of partnerIDs) {
    const sex = sexByID.get(id);
    if (sex === 'M' && !husband) husband = id;
    else if (sex === 'F' && !wife) wife = id;
    else if (!husband) husband = id;
    else if (!wife) wife = id;
  }
  return {husband, wife};
}

function inferredSexByID(people) {
  const femaleNames = new Set([
    'анна', 'антонина', 'александра', 'галина', 'елена', 'евгения', 'ирина',
    'лидия', 'мария', 'ольга', 'татьяна', 'валентина', 'раиса', 'нина',
    'тамара', 'надежда', 'вера', 'зинаида', 'людмила', 'екатерина', 'наталья',
    'светлана', 'камиля', 'берта', 'виктория', 'макси', 'alice',
  ]);
  const maleNames = new Set([
    'иван', 'владимир', 'михаил', 'константин', 'яков', 'сергей', 'николай',
    'евгений', 'антон', 'алексей', 'виктор', 'степан', 'илья', 'юрий',
    'дмитрий', 'исаак', 'моисей', 'андрей', 'игнатий', 'александр',
  ]);
  const result = new Map();
  for (const person of people) {
    const given = (person.givenName ?? '').toLowerCase().replaceAll('ё', 'е');
    const family = (person.familyName ?? '').toLowerCase().replaceAll('ё', 'е');
    if (femaleNames.has(given) || given.endsWith('а') || given.endsWith('я') || family.endsWith('ова') || family.endsWith('ева') || family.endsWith('ина')) {
      result.set(person.id, 'F');
    } else if (maleNames.has(given) || family.endsWith('ов') || family.endsWith('ев')) {
      result.set(person.id, 'M');
    }
  }
  return result;
}

function regenerateGedcom(currentText, unions, sexByID) {
  const records = splitGedcomRecords(currentText);
  const famsByPerson = new Map();
  const famcByPerson = new Map();
  for (const union of unions) {
    for (const partnerID of union.partnerIDs) {
      const values = famsByPerson.get(partnerID) ?? [];
      values.push(union.id);
      famsByPerson.set(partnerID, values);
    }
    for (const childID of union.childIDs) {
      const values = famcByPerson.get(childID) ?? [];
      values.push(union.id);
      famcByPerson.set(childID, values);
    }
  }

  const header = [];
  const individuals = [];
  const other = [];
  for (const record of records) {
    const individual = record[0]?.match(/^0 @([^@]+)@ INDI$/);
    if (individual) {
      const id = individual[1];
      const cleaned = record.filter((line) => !/^1 FAM[CS] /.test(line) && !/^1 SEX /.test(line));
      const insertAt = Math.max(1, cleaned.findIndex((line) => /^1 NAME /.test(line)) + 1);
      const relationshipLines = [];
      const sex = sexByID.get(id);
      if (sex) relationshipLines.push(`1 SEX ${sex}`);
      for (const familyID of [...new Set(famsByPerson.get(id) ?? [])].sort()) relationshipLines.push(`1 FAMS @${familyID}@`);
      for (const familyID of [...new Set(famcByPerson.get(id) ?? [])].sort()) relationshipLines.push(`1 FAMC @${familyID}@`);
      cleaned.splice(insertAt, 0, ...relationshipLines);
      individuals.push(cleaned);
    } else if (/^0 @[^@]+@ FAM$/.test(record[0] ?? '') || record[0] === '0 TRLR') {
      continue;
    } else if (individuals.length === 0) {
      header.push(record);
    } else {
      other.push(record);
    }
  }

  const familyRecords = unions.map((union) => {
    const lines = [`0 @${union.id}@ FAM`];
    const {husband, wife} = gedcomRoles(union.partnerIDs, sexByID);
    if (husband) lines.push(`1 HUSB @${husband}@`);
    if (wife) lines.push(`1 WIFE @${wife}@`);
    for (const childID of union.childIDs) lines.push(`1 CHIL @${childID}@`);
    if (union.marriageDate || union.relationshipStatus === 'married') {
      lines.push('1 MARR');
      if (union.marriageDate) lines.push(`2 DATE ${union.marriageDate}`);
    }
    if (union.relationshipStatus === 'divorced') {
      lines.push('1 DIV');
      if (union.statusDate) lines.push(`2 DATE ${union.statusDate}`);
    }
    return lines;
  });
  return [...header, ...individuals, ...familyRecords, ...other, ['0 TRLR']]
    .flat()
    .join('\n') + '\n';
}

function validate(people, unions) {
  const ids = new Set(people.map((person) => person.id));
  const problems = [];
  for (const union of unions) {
    if (union.partnerIDs.length > 2) problems.push(`${union.id} has more than two partners`);
    for (const id of [...union.partnerIDs, ...union.childIDs]) if (!ids.has(id)) problems.push(`${union.id} references missing ${id}`);
  }
  for (const person of people) {
    if (person.immediateFamily.parents.length > 2) problems.push(`${person.id} has more than two parents`);
    for (const parentID of person.immediateFamily.parents) {
      const parent = people.find((candidate) => candidate.id === parentID);
      if (!parent?.immediateFamily.children.includes(person.id)) problems.push(`${person.id}/${parentID} is not reciprocal`);
    }
  }
  if (problems.length) throw new Error(`Relationship validation failed:\n${problems.join('\n')}`);
}

const args = parseArguments(process.argv.slice(2));
const store = path.resolve(args.store);
const backup = path.resolve(args.backup);
const corrections = readJson(path.resolve(args.corrections));
const manifestPath = path.join(store, 'manifest.json');
const peoplePath = path.join(store, 'people');
const manifest = readJson(manifestPath);
const people = fs.readdirSync(peoplePath)
  .filter((filename) => filename.endsWith('.json'))
  .map((filename) => readJson(path.join(peoplePath, filename)));
const peopleByID = new Map(people.map((person) => [person.id, person]));
const source = args['source-gedcom']
  ? parseSourceFamilies(fs.readFileSync(path.resolve(args['source-gedcom']), 'utf8'))
  : {families: [], sexByID: inferredSexByID(people)};
for (const [personID, sex] of inferredSexByID(people)) {
  if (!source.sexByID.has(personID)) source.sexByID.set(personID, sex);
}

applyParentOverrides(peopleByID, corrections.parentOverrides);
const unions = deriveUnions(people, source.families, corrections);
rebuildCompatibilityIndex(people, unions);
validate(people, unions);
copyBackup(store, backup);

for (const person of people) writeJson(path.join(peoplePath, `${person.id}.json`), person);
writeJson(path.join(store, 'family-unions.json'), unions);
manifest.version = Math.max(2, manifest.version ?? 1);
manifest.schemaVersion = Math.max(2, manifest.schemaVersion ?? 1);
manifest.updatedAt = new Date().toISOString();
writeJson(manifestPath, manifest);
fs.mkdirSync(path.join(store, 'PrivateData'), {recursive: true});
writeJson(path.join(store, 'PrivateData', 'relationship-corrections.private.json'), corrections);
const currentGedcomPath = path.join(store, 'family.ged');
fs.writeFileSync(currentGedcomPath, regenerateGedcom(fs.readFileSync(currentGedcomPath, 'utf8'), unions, source.sexByID));

console.log(JSON.stringify({
  people: people.length,
  unions: unions.length,
  correctedChildren: Object.keys(corrections.parentOverrides ?? {}).length,
  threeParentRecords: people.filter((person) => person.immediateFamily.parents.length > 2).length,
  backup,
}, null, 2));
