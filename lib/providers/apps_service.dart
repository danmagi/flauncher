/*
 * FLauncher
 * Copyright (C) 2021  Étienne Fesser
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:collection';

import 'package:flauncher/database.dart';
import 'package:flauncher/flauncher_channel.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:moor/moor.dart';

class AppsService extends ChangeNotifier {
  final FLauncherChannel _fLauncherChannel;
  final FLauncherDatabase _database;

  List<CategoryWithApps> _categoriesWithApps = [];

  List<App> _hiddenApplications = [];

  List<CategoryWithApps> get categoriesWithApps => _categoriesWithApps
      .map((item) => CategoryWithApps(item.category, UnmodifiableListView(item.applications)))
      .toList(growable: false);

  List<App> get hiddenApplications => UnmodifiableListView(_hiddenApplications);

  AppsService(this._fLauncherChannel, this._database) {
    _init();
  }

  Future<void> _init() async {
    await _refreshState();
    _fLauncherChannel.addAppsChangedListener(_onAppsChanged);
  }

  Future<void> _onAppsChanged(Map<dynamic, dynamic> event) async {
    await _refreshState();
  }

  Future<void> _refreshState() async {
    final appsFromSystem = (await _fLauncherChannel.getInstalledApplications())
        .map((data) => AppsCompanion(
              packageName: Value(data["packageName"]),
              name: Value(data["name"]),
              version: Value(data["version"]),
              banner: Value(data["banner"]),
              icon: Value(data["icon"]),
              hidden: Value.absent(),
            ))
        .toList();

    List<App> applications = await _database.listApplications();

    final List<String> newAppsPackages = appsFromSystem
        .map((systemApp) => systemApp.packageName.value)
        .where((systemApp) => !applications.any((app) => app.packageName == systemApp))
        .toList();

    final uninstalledApplications = applications
        .where((app) => !appsFromSystem.any((systemApp) => systemApp.packageName.value == app.packageName))
        .map((app) => app.packageName)
        .toList();

    await _database.persistApps(appsFromSystem);
    await _database.deleteApps(uninstalledApplications);
    applications = await _database.listApplications();

    if (newAppsPackages.isNotEmpty) {
      final applicationsCategory = await _database.getCategory("Applications");
      int index = await _database.nextAppCategoryOrder(applicationsCategory.id);
      final newAppCategories = newAppsPackages
          .map((systemAppPackage) => AppsCategoriesCompanion.insert(
              categoryId: applicationsCategory.id, appPackageName: systemAppPackage, order: index++))
          .toList();
      await _database.insertAppsCategories(newAppCategories);
    }
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    _hiddenApplications = await _database.listHiddenApplications();
    notifyListeners();
  }

  Future<void> launchApp(App app) => _fLauncherChannel.launchApp(app.packageName);

  Future<void> openAppInfo(App app) => _fLauncherChannel.openAppInfo(app.packageName);

  Future<void> uninstallApp(App app) => _fLauncherChannel.uninstallApp(app.packageName);

  Future<void> openSettings() => _fLauncherChannel.openSettings();

  Future<bool> isDefaultLauncher() => _fLauncherChannel.isDefaultLauncher();

  Future<void> moveToCategory(App app, Category oldCategory, Category newCategory) async {
    await _database.deleteAppCategory(oldCategory.id, app.packageName);

    int index = await _database.nextAppCategoryOrder(newCategory.id);
    await _database.insertAppCategory(
      AppsCategoriesCompanion.insert(
        categoryId: newCategory.id,
        appPackageName: app.packageName,
        order: index,
      ),
    );
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> saveOrderInCategory(Category category) async {
    final applications = _categoriesWithApps.firstWhere((element) => element.category.id == category.id).applications;
    final orderedAppCategories = <AppsCategoriesCompanion>[];
    for (int i = 0; i < applications.length; ++i) {
      orderedAppCategories.add(AppsCategoriesCompanion(
        categoryId: Value(category.id),
        appPackageName: Value(applications[i].packageName),
        order: Value(i),
      ));
    }
    await _database.replaceAppsCategories(orderedAppCategories);
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  void reorderApplication(Category category, int oldIndex, int newIndex) {
    final applications = _categoriesWithApps.firstWhere((element) => element.category.id == category.id).applications;
    final application = applications.removeAt(oldIndex);
    applications.insert(newIndex, application);
    notifyListeners();
  }

  Future<void> addCategory(String categoryName) async {
    if (categoryName == "Applications") {
      return;
    }
    final orderedCategories = <CategoriesCompanion>[];
    for (int i = 0; i < _categoriesWithApps.length; ++i) {
      final category = _categoriesWithApps[i].category;
      orderedCategories.add(category.toCompanion(false).copyWith(order: Value(i + 1)));
    }
    await _database.insertCategory(CategoriesCompanion.insert(name: categoryName, order: 0));
    await _database.updateCategories(orderedCategories);
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> renameCategory(Category category, String categoryName) async {
    if (categoryName == "Applications") {
      return;
    }
    await _database.updateCategory(category.id, CategoriesCompanion(name: Value(categoryName)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> deleteCategory(Category category) async {
    final applicationsCategory = _categoriesWithApps.firstWhere((e) => e.category.name == "Applications").category;
    final applications = await _database.listCategoryApps(category.id);
    int index = await _database.nextAppCategoryOrder(applicationsCategory.id);
    final appsCategories = applications
        .map((app) => AppsCategoriesCompanion.insert(
              categoryId: applicationsCategory.id,
              appPackageName: app.packageName,
              order: index++,
            ))
        .toList();
    await _database.replaceAppsCategories(appsCategories);
    await _database.deleteCategory(category.id);
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> moveCategory(int oldIndex, int newIndex) async {
    final categoryWithApps = _categoriesWithApps.removeAt(oldIndex);
    _categoriesWithApps.insert(newIndex, categoryWithApps);
    final orderedCategories = <CategoriesCompanion>[];
    for (int i = 0; i < _categoriesWithApps.length; ++i) {
      final category = _categoriesWithApps[i].category;
      orderedCategories.add(CategoriesCompanion(id: Value(category.id), order: Value(i)));
    }
    await _database.updateCategories(orderedCategories);
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> hideApplication(App application) async {
    await _database.updateApp(application.packageName, AppsCompanion(hidden: Value(true)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    _hiddenApplications = await _database.listHiddenApplications();
    notifyListeners();
  }

  Future<void> unHideApplication(App application) async {
    await _database.updateApp(application.packageName, AppsCompanion(hidden: Value(false)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    _hiddenApplications = await _database.listHiddenApplications();
    notifyListeners();
  }

  Future<void> setCategoryDisplay(Category category, CategoryDisplay display) async {
    await _database.updateCategory(category.id, CategoriesCompanion(display: Value(display)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> setCategorySort(Category category, CategorySort sort) async {
    await _database.updateCategory(category.id, CategoriesCompanion(sort: Value(sort)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> setCategoryColumnsCount(Category category, int columnsCount) async {
    await _database.updateCategory(category.id, CategoriesCompanion(columnsCount: Value(columnsCount)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }

  Future<void> setCategoryRowHeight(Category category, int rowHeight) async {
    await _database.updateCategory(category.id, CategoriesCompanion(rowHeight: Value(rowHeight)));
    _categoriesWithApps = await _database.listCategoriesWithVisibleApps();
    notifyListeners();
  }
}
